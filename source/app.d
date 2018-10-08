import std.experimental.all;
import derelict.freeimage.freeimage;

version (Windows) extern(Windows) int SetConsoleOutputCP(uint);

//alias Pixel = ubyte;
alias CoordinateInt = ReturnType!FreeImage_GetWidth;

int main(string[] args)
{   version (Windows) SetConsoleOutputCP(65001);
    DerelictFI.load();

    if (args.length != 2)
    {   writeln("Tarvitaan yksi argumentti: tiedoston nimi");
        return 0;
    }

    if (args[1].extension.toLower != ".gif")
    {   writeln("Ohjelma on tarkoitettu vain gif-teidostoihin, tällä hetkellä");
        return 0;
    }

    immutable(wchar)* cPath = (args[1].to!wstring ~ '\0').ptr;

    auto bitmap = FreeImage_LoadU(FIF_GIF, cPath, 0);
    if (bitmap is null)
    {   writeln("Tiedosto ei auennut. Tarkista polku ja, jos se on kunnossa, käyttöoikeudet.");
        return 0;
    }
    scope (exit) bitmap.FreeImage_Unload;

    if(!bitmap.FreeImage_HasPixels)
    {   writeln("Tyhjä kuvatiedosto. Ei kelpaa.");
        return 0;
    }

    CoordinateInt pixelBits = bitmap.FreeImage_GetBPP;

    auto dimensions = [bitmap.FreeImage_GetWidth, bitmap.FreeImage_GetHeight].staticArray;
    auto sideCoords = [dimensions[0], 0].staticArray!CoordinateInt;
    auto bottomUpCoords = [dimensions[1], 0].staticArray!CoordinateInt;

    assert(pixelBits == 8);
    auto transparentColours = bitmap
        .FreeImage_GetTransparencyTable[0 .. bitmap.FreeImage_GetTransparencyCount]
        .uniq
        .array
        .pipe!(a => a ~ *bitmap.FreeImage_GetScanLine(0))
        .sort;

    //foreach(col; transparentColours) col.writeln;;

    iota(dimensions[1])
    .map!(pixelY => bitmap.FreeImage_GetScanLine(pixelY)[0 .. to!CoordinateInt(dimensions[0] * pixelBits / ubyte.sizeof)])
    .map!(pixelLine =>
        dimensions[0]
        .iota
        .map!(index => pixelLine[index])
        .enumerate!CoordinateInt
        .filterBidirectional!(px => !(px.value in transparentColours))
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
    {   writeln("Koko kuva on täysin läpinäkyvä. Ei jäisi mitään jäljelle, joten ei leikata.");
        return 0;
    }
    assert(bottomUpCoords[1] > bottomUpCoords[0]);

    auto newBitmap = bitmap.FreeImage_Copy
    (   sideCoords[0],
        dimensions[1] - bottomUpCoords[1],
        sideCoords[1],
        dimensions[1] - bottomUpCoords[0],
    );
    scope (exit) newBitmap.FreeImage_Unload;

    if (FreeImage_SaveU(FIF_GIF, newBitmap, cPath, 0)) writeln("Onnistui, marginaalit leikattu");
    else writeln("Ohjelma avasi kuvan ja leikkasi marginaalit, muttei jostain syystä pystynyt tallentamaan tulosta.");

    return 0;
}

////////////////////////////////////////////
// yleisfunktioita
////////////////////////////////////////////

auto ref tuplify(E, size_t n)(E[n] array)
{   return array
    .Tuple!(Repeat!(n, double));
}
alias tupArg(alias func) = x => func(x.expand);

auto staticArray(E, size_t n)(E[n] elements){return elements;}
auto staticArray(size_t n, R)(R elements)
{   typeof(elements.front)[n] result;
    elements.take(n).copy(result[]);
    return result;
}
