/*
Copyright (c) 2016-2017 Timur Gafarov

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

module dlib.image.io.hdr;

import std.stdio;
import std.math;
import dlib.core.memory;
import dlib.core.stream;
import dlib.core.compound;
import dlib.container.array;
import dlib.filesystem.local;
import dlib.image.color;
import dlib.image.image;
import dlib.image.hdri;
import dlib.image.io.io;

/*
 * Radiance HDR/RGBE decoder
 */

void readLineFromStream(InputStream istrm, ref DynamicArray!char line)
{
    char c;
    do
    {
        if (istrm.readable)
            istrm.readBytes(&c, 1);
        else
            break;

        if (c != '\n')
            line.append(c);
    }
    while(c != '\n');
}

class HDRLoadException: ImageLoadException
{
    this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable next = null)
    {
        super(msg, file, line, next);
    }
}

/*
 * Load HDR from file using local FileSystem.
 * Causes GC allocation
 */
SuperHDRImage loadHDR(string filename)
{
    InputStream input = openForInput(filename);
    auto img = loadHDR(input);
    input.close();
    return img;
}

/*
 * Load HDR from stream using default image factory.
 * Causes GC allocation
 */
SuperHDRImage loadHDR(InputStream istrm)
{
    Compound!(SuperHDRImage, string) res =
        loadHDR(istrm, defaultHDRImageFactory);
    if (res[0] is null)
        throw new HDRLoadException(res[1]);
    else
        return res[0];
}

/*
 * Load HDR from stream using specified image factory.
 * GC-free
 */
Compound!(SuperHDRImage, string) loadHDR(
    InputStream istrm,
    SuperHDRImageFactory imgFac)
{
    SuperHDRImage img = null;

    Compound!(SuperHDRImage, string) error(string errorMsg)
    {
        if (img)
        {
            img.free();
            img = null;
        }
        return compound(img, errorMsg);
    }

    char[11] magic;
    istrm.fillArray(magic);
    if (magic != "#?RADIANCE\n")
    {
        if (magic[0..7] == "#?RGBE\n")
        {
            istrm.position = 7;
        }
        else
            return error("loadHDR error: signature check failed");
    }

    // Read header
    DynamicArray!char line;
    do
    {
        line.free();
        readLineFromStream(istrm, line);
        // TODO: parse assignments
    }
    while (line.length);

    // Read resolution line
    line.free();
    readLineFromStream(istrm, line);

    char xsign, ysign;
    uint width, height;
    int count = sscanf(line.data.ptr, "%cY %u %cX %u", &ysign, &height, &xsign, &width);
    if (count != 4)
        return error("loadHDR error: invalid resolution line");

    // Read pixel data
    ubyte[] dataRGBE = New!(ubyte[])(width * height * 4);
    ubyte[4] col;
    for (uint y = 0; y < height; y++)
    {
        istrm.readBytes(col.ptr, 4);
        //Header of 0x2, 0x2 is new Radiance RLE scheme
        if (col[0] == 2 && col[1] == 2 && col[2] >= 0)
        {
            // Each channel is run length encoded seperately
            for (uint chi = 0; chi < 4; chi++)
            {
                uint x = 0;
                while (x < width)
                {
                    uint start = (y * width + x) * 4;
                    ubyte num = 0;
                    istrm.readBytes(&num, 1);
                    if (num <= 128) // No run, just read the values
                    {
                        for (uint i = 0; i < num; i++)
                        {
                            ubyte value;
                            istrm.readBytes(&value, 1);
                            dataRGBE[start + chi + i*4] = value;
                        }
                    }
                    else // We have a run, so get the value and set all the values for this run
                    {
                        ubyte value;
                        istrm.readBytes(&value, 1);
                        num -= 128;
                        for (uint i = 0; i < num; i++)
                        {
                            dataRGBE[start + chi + i*4] = value;
                        }
                    }

                    x += num;
                }
            }
        }
        else // Old Radiance RLE scheme
        {
            for (uint x = 0; x < width; x++)
            {
                if (x > 0)
                    istrm.readBytes(col.ptr, 4);

                uint prev = (y * width + x - 1) * 4;
                uint start = (y * width + x) * 4;

                // Check for the RLE header for this scanline
                if (col[0] == 1 && col[1] == 1 && col[2] == 1)
                {
                    // Do the run
                    int num = (cast(int)col[3]) & 0xFF;

                    ubyte r = dataRGBE[prev];
                    ubyte g = dataRGBE[prev + 1];
                    ubyte b = dataRGBE[prev + 2];
                    ubyte e = dataRGBE[prev + 3];

                    for (uint i = 0; i < num; i++)
                    {
                        dataRGBE[start + i*4 + 0] = r;
                        dataRGBE[start + i*4 + 1] = g;
                        dataRGBE[start + i*4 + 2] = b;
                        dataRGBE[start + i*4 + 3] = e;
                    }

                    x += num-1;
                }
                else // No runs here, just read the data
                {
                    dataRGBE[start] = col[0];
                    dataRGBE[start + 1] = col[1];
                    dataRGBE[start + 2] = col[2];
                    dataRGBE[start + 3] = col[3];
                }
            }
        }
    }

    // Convert RGBE to IEEE floats
    img = imgFac.createImage(width, height); //new FPImage(width, height);
    foreach(y; 0..height)
    foreach(x; 0..width)
    {
        size_t start = (width * y + x) * 4;
        ubyte exponent = dataRGBE[start + 3];
        if (exponent == 0)
        {
            img[x, y] = Color4f(0, 0, 0, 1);
        }
        else
        {
            float v = ldexp(1.0, cast(int)exponent - (128 + 8));
            float r = cast(float)(dataRGBE[start]) * v;
            float g = cast(float)(dataRGBE[start + 1]) * v;
            float b = cast(float)(dataRGBE[start + 2]) * v;
            img[x, y] = Color4f(r, g, b, 1);
        }
    }

    Delete(dataRGBE);

    return compound(img, "");
}
