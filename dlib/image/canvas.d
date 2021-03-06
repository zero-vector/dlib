/*
Copyright (c) 2018 Timur Gafarov

Boost Software License - Version 1.0 - August 17th, 2003

Permission is hereby granted, free of charge, to any person or organization
obtaining a copy of the software and accompanying documentation covered by
this license (the "Software") to use, reproduce, display, distribute,
execute, and transmit the Software, and to prepare derivative works of the
Software, and to permit third-parties to whom the Software is furnished to
do so, all subject to the following:

The copyright notices in the Software and this entire statement, including
the above license grant, this restriction and the following disclaimer,
must be included in all copies of the Software, in whole or in part, and
all derivative works of the Software, unless such copies or derivative
works are solely in the form of machine-executable object code generated by
a source language processor.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE, TITLE AND NON-INFRINGEMENT. IN NO EVENT
SHALL THE COPYRIGHT HOLDERS OR ANYONE DISTRIBUTING THE SOFTWARE BE LIABLE
FOR ANY DAMAGES OR OTHER LIABILITY, WHETHER IN CONTRACT, TORT OR OTHERWISE,
ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS IN THE SOFTWARE.
*/

module dlib.image.canvas;

import std.math;

import dlib.math.vector;
import dlib.math.matrix;
import dlib.math.transformation;
import dlib.math.utils;
import dlib.geometry.bezier;
import dlib.container.array;
import dlib.image.color;
import dlib.image.image;
import dlib.image.render.shapes;

struct CanvasState
{
    Matrix3x3f transformation;
    Color4f lineColor;
    Color4f fillColor;
    float lineWidth;
}

enum SegmentType
{
    Line,
    BezierCubic
}

struct ContourSegment
{
    Vector2f p1;
    Vector2f p2;
    Vector2f p3;
    Vector2f p4;
    float radius;
    SegmentType type;
}

/*
 * A simple 2D vector engine inspired by HTML5 canvas.
 * Supports rendering arbitrary polygons and cubic Bezier paths, filled and outlined.
 * Not real-time, best suited for offline graph plotting.
 */

class Canvas
{
   protected:
    SuperImage _image;
    SuperImage tmpBuffer;

    // TODO: state stack
    CanvasState state;

    DynamicArray!ContourSegment contour;
    Vector2f penPosition;
    
    float tesselationStep = 1.0f / 40.0f;
    uint subpixelResolution = 4;

   public:
    this(SuperImage img)
    {
        _image = img;

        tmpBuffer = image.createSameFormat(_image.width, _image.height);

        state.transformation = Matrix3x3f.identity;
        state.lineColor = Color4f(0.0f, 0.0f, 0.0f, 1.0f);
        state.fillColor = Color4f(0.0f, 0.0f, 0.0f, 1.0f);
        state.lineWidth = 1.0f;

        penPosition = Vector2f(0.0f, 0.0f);
    }

    ~this()
    {
        contour.free();
        tmpBuffer.free();
    }

   public:
    SuperImage image() @property
    {
        return _image;
    }

    void fillColor(Color4f c) @property
    {
        state.fillColor = c;
    }

    Color4f fillColor() @property
    {
        return state.fillColor;
    }

    void lineColor(Color4f c) @property
    {
        state.lineColor = c;
    }

    Color4f lineColor() @property
    {
        return state.lineColor;
    }

    void lineWidth(float w) @property
    {
        state.lineWidth = w;
    }

    float lineWidth() @property
    {
        return state.lineWidth;
    }

    void resetTransform()
    {
        state.transformation = Matrix3x3f.identity;
    }

    void translate(float x, float y)
    {
        state.transformation *= translationMatrix2D(Vector2f(x, y));
    }
    
    void rotate(float a)
    {
        state.transformation *= rotationMatrix2D(a);
    }

    void scale(float x, float y)
    {
        state.transformation *= scaleMatrix2D(Vector2f(x, y));
    }

    void clear(Color4f c)
    {
        dlib.image.render.shapes.fillColor(_image, c);
    }

    void beginPath()
    {
        penPosition = Vector2f(0.0f, 0.0f);
    }

    void endPath()
    {
        contour.free();
    }

    void pathMoveTo(float x, float y)
    {
        penPosition = Vector2f(x, y);
    }

    void pathLineTo(float x, float y)
    {
        Vector2f p1 = penPosition;
        Vector2f p2 = Vector2f(x, y);
        pathAddLine(p1, p2);
        penPosition = p2;
    }

    void pathBezierTo(Vector2f cp1, Vector2f cp2, Vector2f endPoint)
    {
        pathAddBezierCubic(penPosition, cp1, cp2, endPoint);
        penPosition = endPoint;
    }

    void pathStroke()
    {
        dlib.image.render.shapes.fillColor(tmpBuffer, Color4f(0, 0, 0, 0));
        drawContour();       
        blitTmpBuffer(state.lineColor);
    }

    void pathFill()
    {
        dlib.image.render.shapes.fillColor(tmpBuffer, Color4f(0, 0, 0, 0));
        fillShape();
        CanvasState oldState = state;
        state.lineWidth = 2.0f;
        drawContour();
        state = oldState;
        blitTmpBuffer(state.fillColor);
    }

   protected:
    void pathAddLine(Vector2f p1, Vector2f p2)
    {
        ContourSegment segment;
        segment.p1 = p1;
        segment.p2 = p2;
        segment.type = SegmentType.Line;
        contour.append(segment);
    }

    void pathAddBezierCubic(Vector2f p1, Vector2f p2, Vector2f p3, Vector2f p4)
    {
        ContourSegment segment;
        segment.p1 = p1;
        segment.p2 = p2;
        segment.p3 = p3;
        segment.p4 = p4;
        segment.type = SegmentType.BezierCubic;
        contour.append(segment);
    }

    void fillShape()
    {
        DynamicArray!Vector2f poly;

        Vector2f tp1, tp2, tp3, tp4;
        
        foreach(i, ref p; contour.data)
        {
            if (p.type == SegmentType.Line)
            {
                tp1 = p.p1.affineTransform2D(state.transformation);
                tp2 = p.p2.affineTransform2D(state.transformation);
                poly.append(tp1);
                poly.append(tp2);
            }
            else if (p.type == SegmentType.BezierCubic)
            {
                tp1 = p.p1.affineTransform2D(state.transformation);
                tp2 = p.p2.affineTransform2D(state.transformation);
                tp3 = p.p3.affineTransform2D(state.transformation);
                tp4 = p.p4.affineTransform2D(state.transformation);
                poly.append(tp1);

                float t = 0.0f;
                while(t < 1.0f)
                {
                    t += tesselationStep;
                    Vector2f p2 = bezierVector2(tp1, tp2, tp3, tp4, t);
                    poly.append(p2);
                }
            }
        }

        foreach(y; 0..tmpBuffer.height)
        foreach(x; 0..tmpBuffer.width)
        {
            auto p = Vector2f(x, y);
            if (pointInPolygon(p, poly.data))
            {
                float srcAlpha = tmpBuffer[x, y].r;
                tmpBuffer[x, y] = Color4f(min2(srcAlpha + 1.0f, 1.0f), 0, 0, 1);
            }
        }

        poly.free();
    }

    void drawContour()
    {
        Vector2f tp1, tp2, tp3, tp4;
        
        foreach(i, ref p; contour.data)
        {
            if (p.type == SegmentType.Line)
            {
                tp1 = p.p1.affineTransform2D(state.transformation);
                tp2 = p.p2.affineTransform2D(state.transformation);
                drawLine(tp1, tp2);
            }
            else if (p.type == SegmentType.BezierCubic)
            {
                tp1 = p.p1.affineTransform2D(state.transformation);
                tp2 = p.p2.affineTransform2D(state.transformation);
                tp3 = p.p3.affineTransform2D(state.transformation);
                tp4 = p.p4.affineTransform2D(state.transformation);
                drawBezierCurve(tp1, tp2, tp3, tp4);
            }
        }
    }

    void drawLineTangent(Vector2f p1, Vector2f p2, Vector2f t1, Vector2f t2)
    {
        Vector2f n1 = Vector2f(-t1.y, t1.x);
        Vector2f n2 = Vector2f(-t2.y, t2.x);

        Vector2f offset1 = n1 * state.lineWidth * 0.5f;       
        Vector2f offset2 = n2 * state.lineWidth * 0.5f;

        Vector2f[4] poly;
        poly[0] = p1 - offset1;
        poly[1] = p1 + offset1;
        poly[2] = p2 + offset2;
        poly[3] = p2 - offset2;
        
        float subpSize = 1.0f / subpixelResolution;
        float subpContrib = 1.0f / (subpixelResolution * subpixelResolution);

        int xmin = cast(int)min2(min2(poly[0].x, poly[1].x), min2(poly[2].x, poly[3].x)) - 1;
        int ymin = cast(int)min2(min2(poly[0].y, poly[1].y), min2(poly[2].y, poly[3].y)) - 1;
        int xmax = cast(int)max2(max2(poly[0].x, poly[1].x), max2(poly[2].x, poly[3].x)) + 1;
        int ymax = cast(int)max2(max2(poly[0].y, poly[1].y), max2(poly[2].y, poly[3].y)) + 1;

        foreach(y; ymin..ymax)
        foreach(x; xmin..xmax)
        {
            float alpha = 0.0f;

            foreach(sy; 0..subpixelResolution)
            foreach(sx; 0..subpixelResolution)
            {
                auto p = Vector2f(x + sx * subpSize, y + sy * subpSize);

                if (pointInPolygon(p, poly))
                    alpha += subpContrib;
            }

            float srcAlpha = tmpBuffer[x, y].r;
            tmpBuffer[x, y] = Color4f(min2(srcAlpha + alpha, 1.0f), 0, 0, 1);
        }
    }
    
    void drawLine(Vector2f p1, Vector2f p2)
    {
        Vector2f dir = p2 - p1;
        Vector2f ndir = dir.normalized;
        drawLineTangent(p1, p2, ndir, ndir);
    }

    void drawBezierCurve(Vector2f a, Vector2f b, Vector2f c, Vector2f d)
    {
        Vector2f p1 = a;
        Vector2f t1 = bezierTangentVector2(a, b, c, d, 0.0f).normalized;

        float t = 0.0f;
        while(t < 1.0f)
        {
            t += tesselationStep;
            Vector2f p2 = bezierVector2(a, b, c, d, t);
            Vector2f t2 = bezierTangentVector2(a, b, c, d, t).normalized;
            drawLineTangent(p1, p2, t1, t2);
            p1 = p2;
            t1 = t2;
        }
    }

    void blitTmpBuffer(Color4f color)
    {
        foreach(y; 0.._image.width)
        foreach(x; 0.._image.height)
        {
            Color4f c1 = _image[x, y];
            Color4f c2 = color;
            c2.a = tmpBuffer[x, y].r * color.a;
            _image[x, y] = alphaOver(c1, c2);
        }
    }
}

bool pointInPolygon(Vector2f p, Vector2f[] poly)
{
    size_t i = 0;
    size_t j = poly.length - 1;
    bool inside = false;

    for (i = 0; i < poly.length; i++)
    {
        Vector2f a = poly[i];
        Vector2f b = poly[j];

        if ((a.y > p.y) != (b.y > p.y) &&
            (p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x))
            inside = !inside;

        j = i;
    }

    return inside;
}

