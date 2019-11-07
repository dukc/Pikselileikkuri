import std;
import bindbc.freeimage;
import std.getopt : optConfig = config;

version (Windows) extern(Windows) int SetConsoleOutputCP(uint);

alias Pixel = uint;
alias CoordinateInt = ReturnType!FreeImage_GetWidth;
alias Bitmap = ReturnType!FreeImage_Load;

enum Ortho{right, down, left, up}
enum supportedFileExtensions = [".gif", ".png"].sort;

version (Windows) alias loadImage = FreeImage_LoadU;
else alias loadImage = FreeImage_Load;

version (Windows) alias saveImage = FreeImage_SaveU;
else alias saveImage = FreeImage_Save;

int main(string[] args)
{   version (Windows) SetConsoleOutputCP(65001);
    auto loadResult = loadFreeImage();
    if (loadResult != fiSupport)
    {	writeln("FreeImagessa vikaa, latauksen tulos ", loadResult);
		if (loadResult == FISupport.noLibrary) return 1;
	}

    ushort rgbColour = ushort.max;
    Nullable!(uint[EnumMembers!Ortho.length]) wantedMarginals;

    try
    {   string colourString = "";
        string marginalString = "";
        auto info = getopt
        (   args,
            optConfig.stopOnFirstNonOption,
            "colour|c", "Väri johon muuttaa kuva", &colourString,
            "marginals|m", "Leikataan marginaalit pois, syötä joko vaaka - ja pystymarginaali tai oikea-ala-vasen-ylämarginaali", &marginalString,
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

        if (!marginalString.empty)
        {   auto parsedMarginalString = marginalString.parseMarginalSize;
            if (not(parsedMarginalString.hasValue))
            {   writeln("marginaaliarvo syötetty väärin. Syötä 0, 2 tai 4 kokonaislukua väleillä erotettuna");
                return 0;
            }
            wantedMarginals = parsedMarginalString;
        }

        if (colourString.empty && wantedMarginals.isNull)
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

    version (Windows) immutable(wchar)* cPath = (args[$ - 1].to!wstring ~ '\0').ptr;
    else immutable(char)* cPath = (args[$ - 1] ~ '\0').ptr;

    auto bitmap0 = fileExt.predSwitch
    (   ".gif", loadImage(FIF_GIF, cPath, GIF_PLAYBACK),
        ".png", loadImage(FIF_PNG, cPath, 0           ),
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

    auto finalBitmap = wantedMarginals.hasValue? bitmap0.cutMarginals(wantedMarginals.get).visit!
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
        {   auto alphaMask = ~
            (   finalBitmap.FreeImage_GetRedMask   |
                finalBitmap.FreeImage_GetGreenMask |
                finalBitmap.FreeImage_GetBlueMask
            );

            //Etsitään väri jota kuvassa ei vielä ole
            Pixel backgroundColour;
            if (true)
            {   // Höh, mokoma operaatio vain jotta löytyisi sopiva taustaväri. Ei olisi
                // pahitteeksi jos tämän saisi optimoitua pois.
                Bitmap testMap = finalBitmap.FreeImage_ColorQuantize(FIQ_WUQUANT);
                Mt19937 rng;
                scope (exit) testMap.FreeImage_Unload;
                assert(testMap != null);

                electMarker:
                backgroundColour = rng.front | alphaMask;
                rng.popFront();

                //Jos väri on jo kuvassa, uudestaan.
                if
                (   (cast(Pixel*)testMap.FreeImage_GetPalette)
                    [0 .. testMap.FreeImage_GetColorsUsed]
                    .canFind(backgroundColour)
                ) goto electMarker;
            }

            // FreeImage_ColorQuantize() ei tunnu huomioivan läpinäkyvyyttä, joten muutetaan läpinäkymättömät kohdat äsken arvotulle
            // taustavärille sen ajaksi. Melkoisen tehotonta että niin joutuu tekemään kyllä, mutta en keksi parempaa.
            foreach(lineY; iota(finalBitmap.FreeImage_GetHeight))
                foreach(ref px; (cast(Pixel*) finalBitmap.FreeImage_GetScanLine(lineY))[0 .. finalBitmap.FreeImage_GetWidth])
            {   if (!(px & alphaMask)) px = backgroundColour;
            }

            Bitmap palettized = finalBitmap.FreeImage_ColorQuantize(FIQ_WUQUANT);
            scope (exit) palettized.FreeImage_Unload;
            assert(palettized != null);

            //taustaväri läpinäkyväksi
            palettized.FreeImage_SetTransparentIndex
            (   palettized.FreeImage_GetPalette[0 .. palettized.FreeImage_GetColorsUsed]
                .map!
                (   quad
                    => quad.rgbRed * (finalBitmap.FreeImage_GetRedMask / 0xFF)
                    | quad.rgbGreen * (finalBitmap.FreeImage_GetGreenMask / 0xFF)
                    | quad.rgbBlue * (finalBitmap.FreeImage_GetBlueMask / 0xFF)
                    | alphaMask
                )
                .until(backgroundColour).walkLength.to!int
            );

            writefln("bc:%x, i:%s", backgroundColour, palettized.FreeImage_GetTransparentIndex);

            return saveImage(FIF_GIF, palettized, cPath, 0);
        }(),
        ".png", saveImage(FIF_PNG, finalBitmap, cPath, 0)
    ))
    {   //älä muuta tätä viestiä noin vain: Kaiverrusgalleria käyttää sitä
        writeln("Ohjelma ajettu onnistuneesti.");
    }
    else writeln("Ohjelma avasi kuvan ja teki operaatiot, muttei jostain syystä pystynyt tallentamaan tulosta.");

    return 0;
}

Algebraic!(Bitmap, string) cutMarginals(Bitmap bitmap, CoordinateInt[EnumMembers!Ortho.length] marginals = [0, 0, 0, 0])
{   import mir.ndslice : windows;

    writeln("Karsitaan marginaaleja");
    CoordinateInt pixelBits = bitmap.FreeImage_GetBPP;

    auto dimensions = [bitmap.FreeImage_GetWidth, bitmap.FreeImage_GetHeight].staticArray;
    auto sideCoords = [dimensions[0], 0].staticArray!CoordinateInt;
    auto bottomUpCoords = [dimensions[1], 0].staticArray!CoordinateInt;

    assert(bitmap.FreeImage_GetBPP / 8 == Pixel.sizeof);
    assert(!(bitmap.FreeImage_GetBPP % 8));

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

    auto newDimensions =
    [   sideCoords[1] - sideCoords[0] + marginals[Ortho.left] + marginals[Ortho.right],
        bottomUpCoords[1] - bottomUpCoords[0] + marginals[Ortho.down] + marginals[Ortho.up]
    ].staticArray;

    if (sideCoords[1] <= sideCoords[0])
    {   return typeof(return)("Koko kuva on täysin läpinäkyvä. Marginaalileikkaus ei jättäisi mitään jäljelle, joten ohjelma ei tehnyt mitään.");
    }
    assert(bottomUpCoords[1] > bottomUpCoords[0]);

    auto result = FreeImage_Allocate(newDimensions[0], newDimensions[1], Pixel.sizeof * 8);

    assert (result != null);

    result.getBits
    .windows(bottomUpCoords[1] - bottomUpCoords[0], sideCoords[1] - sideCoords[0])
    [marginals[Ortho.down], marginals[Ortho.left]][]
    = bitmap.getBits
    .windows(bottomUpCoords[1] - bottomUpCoords[0], sideCoords[1] - sideCoords[0])
    [bottomUpCoords[0], sideCoords[0]][];

    return typeof(return)(result);
}

Nullable!(uint[Ortho.max + 1]) parseMarginalSize(CharRange)(CharRange input)
    if (is(typeof(input.byCodeUnit.front) : dchar))
{   try
    {   auto numbers = input.byCodeUnit
        .splitter!(c => !c.isNumber)
        .filter!(range => !range.empty)
        .map!(range => range.array.to!uint)
        .array;

        switch (numbers.length)
        {   case 0: return [0u, 0u, 0u, 0u].staticArray.nullable;
            case 2: return [numbers[0], numbers[1], numbers[0], numbers[1]].staticArray.nullable;
            case 4: return numbers.staticArray!4.nullable;
            default: return typeof(return).init;
        }
    }
    catch (ConvOverflowException e){}
    catch (ConvException e){}

    return typeof(return).init;
}

auto getBits(Flag!"cutPitch" cutPitch = No.cutPitch)(Bitmap bitmap)
{   import mir.ndslice;

    assert (bitmap !is null);
    auto height = bitmap.FreeImage_GetHeight;
    auto pitch = bitmap.FreeImage_GetPitch;

    auto result = (cast(Pixel[]) bitmap.FreeImage_GetBits[0 .. height * pitch])
    .sliced(height, pitch / Pixel.sizeof);

    static if (cutPitch) return result.windows(height, bitmap.FreeImage_GetWidth)[0, 0];
    else return result;
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

alias not = x => !x;
bool hasValue(NullableType)(NullableType container)
    if(isInstanceOf!(Nullable, NullableType))
{   return !container.isNull;
}
auto ref tuplify(E, size_t n)(E[n] array)
{   return array
    .Tuple!(Repeat!(n, E));
}
alias tupArg(alias func) = x => func(x.expand);
