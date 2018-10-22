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

    ushort rgbColour = ushort.max;
    bool marginalsDisliked = false;

    try
    {   string colourString = "";
        auto info = getopt
        (   args,
            std.getopt.config.stopOnFirstNonOption,
            "colour|c", "Väri johon muuttaa kuva", &colourString,
            "marginals|m", "Leikataan marginaalit pois", &marginalsDisliked,
        );

        if (info.helpWanted)
        {   stdout.lockingTextWriter.defaultGetoptFormatter
            (   "Leikkaa ylimääräiset marginaalit ja/tai jälleenvärittää yksiväriset kuvat.\n"
                ~ text("Käyttö: ", args[0], " argumentit...", " tiedostonnimi\n")
                ~ "(C) Ylivieskan kivihiomo KY\n\n",
                info.options
            );

            return 0;
        }

        if (args.length < 2)
        {   writeln("Tiedoston nimi puuttuu");
            return 0;
        }

        if (args.length > 2)
        {   writeln("Ohjelma nielee vain yhden tiedoston nimen");
            return 0;
        }

        if (colourString != "" &&
        (   colourString.length != 3
            || (colourString).toLower.formattedRead!("%x")(rgbColour) < 1
        ))
        {   throw new Exception
            (   "Värille tai täytön voimalle annettu argumentti väärässä muodossa. Niiden pitää olla 3 ja 1 heksadesimaalinumeroa "
                ~ " eli numeroa 0-9 tai kirjainta a-f tai A-F. (kirjaimet vastaavat numeroita 10-15)"
            );
        }

        if (colourString.empty && !marginalsDisliked)
        {   writeln("Kutsussa ei ole järkeä, koska ohjelmaa ei komennettu varsinaisesti tekemään mitään.");
            writeln("Anna ohjelmalle joko -c tai -m - argumentti (tai molemmat).");
            return 0;
        }
    }
    catch (ConvException e)
    {   throw new Exception("Argumentille syötetty arvo väärässä muodossa.\n" ~ e.message.idup);
    }
    catch (GetOptException e)
    {   throw new Exception("Tuntematon argumentti.\n" ~ e.message.idup);
    }

    auto fileExt = args[1].extension.toLower;

    if (!(fileExt in supportedFileExtensions))
    {   writeln("Tuetut tiedostoliitteet: ", supportedFileExtensions.joiner(", ").array);
        return 0;
    }

    immutable(wchar)* cPath = (args[$ - 1].to!wstring ~ '\0').toLower.ptr;

    auto bitmap0 = fileExt.predSwitch
    (   ".gif", FreeImage_LoadU(FIF_GIF, cPath, GIF_PLAYBACK),
        ".png", FreeImage_LoadU(FIF_PNG, cPath, 0           ),
    );

    if (bitmap0 is null)
    {   writeln("Tiedosto ei auennut. Tarkista polku ja, jos se on kunnossa, käyttöoikeudet.");
        return 0;
    }
    scope (exit) bitmap0.FreeImage_Unload;

    if(!bitmap0.FreeImage_HasPixels)
    {   writeln("Tyhjä kuvatiedosto. Ei kelpaa.");
        return 0;
    }

    auto finalBitmap = marginalsDisliked? bitmap0.cutMarginals.visit!
    (   (Bitmap bm) => bm,
        (string msg)
        {   msg.writeln;
            return Bitmap(null);
        }
    ): bitmap0;
    if (finalBitmap == null) return 0;
    scope (exit) finalBitmap.FreeImage_Unload;

    if(rgbColour < 0x1000) finalBitmap.colourize
    (     finalBitmap.FreeImage_GetRedMask   / 0xF * (rgbColour / 0x100 & 0xF)
        | finalBitmap.FreeImage_GetGreenMask / 0xF * (rgbColour / 0x010 & 0xF)
        | finalBitmap.FreeImage_GetBlueMask  / 0xF * (rgbColour / 0x001 & 0xF)
    );

    if(fileExt.predSwitch
    (   ".gif", ()
        {   auto palettized = finalBitmap.FreeImage_ColorQuantize(FIQ_WUQUANT);
            assert(palettized != null);
            scope (exit) palettized.FreeImage_Unload;

            //palettisointi ei jostain syystä säästä kuvan läpinäkyvyyttä, joten asetetaan se itse.
            CoordinateInt[2] transparentIj = finalBitmap.transparentCoord;
            if (transparentIj[1] < finalBitmap.FreeImage_GetHeight)
            {   ubyte transparentColour;
                auto success = palettized.FreeImage_GetPixelIndex(transparentIj.tuplify.expand, &transparentColour);
                assert(success);
                palettized.FreeImage_SetTransparentIndex(transparentColour);
            }

            return FreeImage_SaveU(FIF_GIF, palettized, cPath, 0);
        }(),
        ".png", FreeImage_SaveU(FIF_PNG, finalBitmap, cPath, 0)
    )) writeln("Ohjelma ajettu onnistuneesti.");
    else writeln("Ohjelma avasi kuvan ja teki operaatiot, muttei jostain syystä pystynyt tallentamaan tulosta.");

    return 0;
}

Algebraic!(Bitmap, string) cutMarginals(Bitmap bitmap)
{   writeln("Karsitaan marginaaleja");
    CoordinateInt pixelBits = bitmap.FreeImage_GetBPP;

    auto dimensions = [bitmap.FreeImage_GetWidth, bitmap.FreeImage_GetHeight].staticArray;
    auto sideCoords = [dimensions[0], 0].staticArray!CoordinateInt;
    auto bottomUpCoords = [dimensions[1], 0].staticArray!CoordinateInt;

    assert(bitmap.FreeImage_GetBPP / 8 == Pixel.sizeof);

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
    {   return typeof(return)("Koko kuva on täysin läpinäkyvä. Marginaalileikkaus ei jättäisi mitään jäljelle, joten ohjelma ei tehnyt mitään.");
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

void colourize(Bitmap bitmap, Pixel how)
{   writeln("vaihdetaan väriä");
    auto dimensions = [bitmap.FreeImage_GetWidth, bitmap.FreeImage_GetHeight].staticArray;

    auto alphaMask = ~
    (   bitmap.FreeImage_GetRedMask   |
        bitmap.FreeImage_GetGreenMask |
        bitmap.FreeImage_GetBlueMask
    );

    foreach(lineY; iota(dimensions[1]))
        foreach(ref px; (cast(Pixel*) bitmap.FreeImage_GetScanLine(lineY))[0 .. to!CoordinateInt(dimensions[0])])
    {   px = px & alphaMask | how & ~alphaMask;
    }
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
