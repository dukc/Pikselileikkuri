import std.experimental.all;
import derelict.freeimage.freeimage;

version (Windows) extern(Windows) int SetConsoleOutputCP(uint);

alias Pixel = uint;
alias CoordinateInt = ReturnType!FreeImage_GetWidth;
alias Bitmap = ReturnType!FreeImage_Load;

enum supportedFileExtensions = [".gif", ".png"].sort;

int main(string[] args)
{   version (Windows) SetConsoleOutputCP(65001);
    DerelictFI.load();

    if (args.length != 2)
    {   writeln("Tarvitaan yksi argumentti: tiedoston nimi");
        return 0;
    }

    auto fileExt = args[1].extension.toLower;

    if (!(fileExt in supportedFileExtensions))
    {   writeln("Tuetut tiedostoliitteet: ", supportedFileExtensions.joiner(", ").array);
        return 0;
    }

    immutable(wchar)* cPath = (args[$ - 1].to!wstring ~ '\0').toLower.ptr;

    auto bitmap = fileExt.predSwitch
    (   ".gif", FreeImage_LoadU(FIF_GIF, cPath, GIF_PLAYBACK),
        ".png", FreeImage_LoadU(FIF_PNG, cPath, 0           ),
    );

    if (bitmap is null)
    {   writeln("Tiedosto ei auennut. Tarkista polku ja, jos se on kunnossa, käyttöoikeudet.");
        return 0;
    }
    scope (exit) bitmap.FreeImage_Unload;

    if(!bitmap.FreeImage_HasPixels)
    {   writeln("Tyhjä kuvatiedosto. Ei kelpaa.");
        return 0;
    }

    auto newBitmap = bitmap.cutMarginals.visit!
    (   (Bitmap bm) => bm,
        (string msg)
        {   msg.writeln;
            return Bitmap(null);
        }
    );
    if (newBitmap == null) return 0;
    scope (exit) newBitmap.FreeImage_Unload;

    if(fileExt.predSwitch
    (   ".gif", ()
        {   auto palettized = newBitmap.FreeImage_ColorQuantize(FIQ_WUQUANT);
            assert(palettized != null);
            scope (exit) palettized.FreeImage_Unload;

            //palettisointi ei jostain syystä säästä kuvan läpinäkyvyyttä, joten asetetaan se itse.
            CoordinateInt[2] transparentIj = newBitmap.transparentCoord;
            if (transparentIj[1] < bitmap.FreeImage_GetHeight)
            {   ubyte transparentColour;
                auto success = palettized.FreeImage_GetPixelIndex(transparentIj.tuplify.expand, &transparentColour);
                assert(success);
                palettized.FreeImage_SetTransparentIndex(transparentColour);
            }

            return FreeImage_SaveU(FIF_GIF, palettized, cPath, 0);
        }(),
        ".png", FreeImage_SaveU(FIF_PNG, newBitmap, cPath, 0)
    )) writeln("Onnistui, marginaalit leikattu");
    else writeln("Ohjelma avasi kuvan ja leikkasi marginaalit, muttei jostain syystä pystynyt tallentamaan tulosta.");

    return 0;
}

Algebraic!(Bitmap, string) cutMarginals(Bitmap bitmap)
{   CoordinateInt pixelBits = bitmap.FreeImage_GetBPP;

    auto dimensions = [bitmap.FreeImage_GetWidth, bitmap.FreeImage_GetHeight].staticArray;
    auto sideCoords = [dimensions[0], 0].staticArray!CoordinateInt;
    auto bottomUpCoords = [dimensions[1], 0].staticArray!CoordinateInt;

    assert(bitmap.FreeImage_GetBPP / 8 == Pixel.sizeof);
    /*auto transparentColours = bitmap
        .FreeImage_GetTransparencyTable[0 .. bitmap.FreeImage_GetTransparencyCount]
        .uniq
        .array
        .pipe!(a => a ~ *bitmap.FreeImage_GetScanLine(0))
        .sort;*/

    auto alphaMask = ~
    (   bitmap.FreeImage_GetRedMask   |
        bitmap.FreeImage_GetGreenMask |
        bitmap.FreeImage_GetBlueMask
    );

    iota(dimensions[1])
    .map!(pixelY => cast(Pixel*)(bitmap.FreeImage_GetScanLine(pixelY))[0 .. to!CoordinateInt(dimensions[0])])
    .map!(pixelLine =>
        dimensions[0]
        .iota
        .map!(index => pixelLine[index])
        .enumerate!CoordinateInt
        .filterBidirectional!(px => px.value & alphaMask)
        .map!(px => px.index))
    .enumerate!CoordinateInt
    .filterBidirectional!(tupArg!((height, opaqueWidths) => !opaqueWidths.empty))
    .pipe!((opaqueLines)
    {   if(!opaqueLines.empty) bottomUpCoords = [opaqueLines.front.index, opaqueLines.back.index + 1].staticArray;

        foreach(opaqueLine; opaqueLines)
        {   sideCoords =
            [   min(sideCoords[0], opaqueLine.value.front),
                max(sideCoords[1], opaqueLine.value.back + 1),
            ];

            if (sideCoords == [0, dimensions[0]]) break;
        }
    });

    auto newDimensions = [sideCoords[1] - sideCoords[0], bottomUpCoords[1] - bottomUpCoords[0]].staticArray;

    if (sideCoords[1] <= sideCoords[0])
    {   return typeof(return)("Koko kuva on täysin läpinäkyvä. Ei jäisi mitään jäljelle, joten ei leikata.");
    }
    assert(bottomUpCoords[1] > bottomUpCoords[0]);

    return typeof(return)(bitmap.FreeImage_Copy
    (   sideCoords[0],
        dimensions[1] - bottomUpCoords[1],
        sideCoords[1],
        dimensions[1] - bottomUpCoords[0],
    ));

}

CoordinateInt[2] transparentCoord(Bitmap bitmap)
{   auto dimensions = [bitmap.FreeImage_GetWidth, bitmap.FreeImage_GetHeight].staticArray;

    auto alphaMask = ~
    (   bitmap.FreeImage_GetRedMask   |
        bitmap.FreeImage_GetGreenMask |
        bitmap.FreeImage_GetBlueMask
    );

    return iota(dimensions[1])
    .map!(pixelY => cast(Pixel*)(bitmap.FreeImage_GetScanLine(pixelY))[0 .. to!CoordinateInt(dimensions[0])])
    .map!(pixelLine =>
        dimensions[0]
        .iota
        .map!(index => pixelLine[index])
        .enumerate!CoordinateInt
        .filter!(px => !(px.value & alphaMask))
        .map!(px => px.index))
    .enumerate!CoordinateInt
    .filter!(tupArg!((height, transparentWidths) => !transparentWidths.empty))
    .map!(tupArg!((height, transparentWidths) => [transparentWidths.front, height].staticArray))
    .chain([0, dimensions[1]].staticArray.only)
    .front
    ;
}

////////////////////////////////////////////
// yleisfunktioita
////////////////////////////////////////////

auto ref tuplify(E, size_t n)(E[n] array)
{   return array
    .Tuple!(Repeat!(n, E));
}
alias tupArg(alias func) = x => func(x.expand);

auto staticArray(E, size_t n)(E[n] elements){return elements;}
auto staticArray(size_t n, R)(R elements)
{   typeof(elements.front)[n] result;
    elements.take(n).copy(result[]);
    return result;
}
