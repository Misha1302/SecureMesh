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
        if (input.Length > 512) throw new ApiError(400, "INVALID_DISPLAY_NAME");
        foreach (var rune in input.EnumerateRunes())
        {
            var category = Rune.GetUnicodeCategory(rune);
            if (category is UnicodeCategory.Control or UnicodeCategory.LineSeparator or UnicodeCategory.ParagraphSeparator ||
                (category == UnicodeCategory.Format && rune.Value != 0x200D))
                throw new ApiError(400, "INVALID_DISPLAY_NAME");
        }
        var name = input.Trim().Normalize(NormalizationForm.FormC);
        if (name.EnumerateRunes().Count() > 64 ||
            (name.Length > 0 && name.EnumerateRunes().All(rune => Rune.GetUnicodeCategory(rune) is
                UnicodeCategory.Format or UnicodeCategory.NonSpacingMark or UnicodeCategory.EnclosingMark or UnicodeCategory.SpaceSeparator)))
            throw new ApiError(400, "INVALID_DISPLAY_NAME");
        return name;
    }
}
