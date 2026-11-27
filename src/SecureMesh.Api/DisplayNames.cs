using System.Globalization;
using System.Text;
using System.Text.Json.Serialization;

namespace SecureMesh;

public sealed record DisplayNameUpdate([property: JsonRequired] string? DisplayName);

public static class DisplayNames
{
    public static string Normalize(string? input)
    {
        if (input is null) return "";
        if (Encoding.UTF8.GetByteCount(input) > 2048) throw new ApiError(400, "INVALID_DISPLAY_NAME");
        foreach (var rune in input.EnumerateRunes())
        {
            var category = Rune.GetUnicodeCategory(rune);
            if (category is UnicodeCategory.Control or UnicodeCategory.LineSeparator or UnicodeCategory.ParagraphSeparator ||
                (rune.Value is >= 0x202A and <= 0x202E or >= 0x2066 and <= 0x2069))
                throw new ApiError(400, "INVALID_DISPLAY_NAME");
        }
        var name = input.Trim().Normalize(NormalizationForm.FormC);
        if (new StringInfo(name).LengthInTextElements > 64 ||
            (name.Length > 0 && name.EnumerateRunes().All(rune => Rune.GetUnicodeCategory(rune) is
                UnicodeCategory.Format or UnicodeCategory.NonSpacingMark or UnicodeCategory.EnclosingMark or UnicodeCategory.SpaceSeparator)))
            throw new ApiError(400, "INVALID_DISPLAY_NAME");
        return name;
    }
}
