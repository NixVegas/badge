# Convert a Spleen BDF (Frederic Cambus, BSD-2-Clause; github fcambus/spleen) into
# a pure-Nix glyph table that draw.nix consumes -- the SAME shape gallant-bdf-to-nix.awk
# emits, so both fonts drop into draw.nix's font-driven text helpers unchanged.
#
# Spleen ships several uniform fixed cells (5x8, 8x16, ...). Each glyph in a given
# BDF is a fixed WxH cell (uniform `BBX W H 0 d`): H BITMAP rows, each a hex word of
# `ceil(W/8)` bytes whose TOP W bits are the glyph columns (bit (bytes*8 - 1) =
# leftmost column x=0). We keep only the printable ASCII range 0x20..0x7e (all
# present in Spleen) so the emitted Nix stays small and NUL-free.
#
# The generator is PARAMETERIZED by the cell metrics so one script serves every
# size: run with `-v width=W -v height=H` (e.g. `-v width=5 -v height=8`).
#
# Output shape (row-major, one int per row, bit (width-1) = leftmost column):
#   {
#     width = 5; height = 8;
#     glyphs = { "48" = [ <height ints> ];  # '0'
#                ... };
#   }
#
# Each row int r has bit (width-1-col) set when pixel (col,row) is lit, so draw.nix
# lights pixel (x+col, y+row) iff (r / 2^(width-1-col)) is odd. No NUL, ints only.
# (This matches gallant-font-data.nix exactly, just at Spleen's cell size.)
BEGIN {
    if (width == 0 || height == 0) {
        print "spleen-bdf-to-nix.awk: need -v width=W -v height=H" > "/dev/stderr";
        exit 1;
    }
    enc = -1; inbits = 0; nrows = 0;
    # Hex digits per BITMAP row word (Spleen pads each row to whole bytes).
    hexdigits = int((width + 7) / 8) * 2;   # 5->2, 8->2, 12->4, 16->4
    totbits = hexdigits * 4;                 # bit (totbits-1) = leftmost col in the word
    # Right-shift to drop the low (totbits-width) padding bits: keeps the top `width`
    # bits as a `width`-bit value, so bit (width-1) is the leftmost column.
    shift = 1;
    for (i = 0; i < totbits - width; i++) shift = shift * 2;   # 2^(totbits-width)

    print "# GENERATED from Spleen " width "x" height ".bdf (fcambus/spleen, BSD-2-Clause). Do not edit.";
    print "# See LICENSE.spleen. width=" width " height=" height ", row-major (bit " (width - 1) " = leftmost col).";
    print "{";
    print "  width = " width ";";
    print "  height = " height ";";
    print "  glyphs = {";
}

/^ENCODING /    { enc = $2 + 0; next }
/^BITMAP/       { if (enc >= 32 && enc <= 126) { inbits = 1; nrows = 0; delete rows } next }
/^ENDCHAR/ {
    if (inbits && enc >= 32 && enc <= 126) {
        # Emit `"<enc>" = [ r0 r1 ... ];`. Convert each hex word to the `width`-bit
        # row by shifting right so bit (width-1) = the word's leftmost column bit.
        line = "    \"" enc "\" = [";
        for (i = 0; i < nrows; i++) {
            w = hex2dec(rows[i]);
            rowW = int(w / shift);   # keep the top `width` bits as a `width`-bit value
            line = line " " rowW;
        }
        line = line " ];";
        print line;
    }
    inbits = 0;
    next
}
{
    if (inbits) {
        # A BITMAP data row: a hex word. Store verbatim.
        rows[nrows] = $0;
        nrows++;
    }
}

END {
    print "  };";
    print "}";
}

# Parse a hex string to a decimal integer (awk has no strtonum in POSIX mode).
function hex2dec(s,    n, i, c, d) {
    n = 0;
    s = toupper(s);
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1);
        if      (c >= "0" && c <= "9") d = c + 0;
        else if (c == "A") d = 10;
        else if (c == "B") d = 11;
        else if (c == "C") d = 12;
        else if (c == "D") d = 13;
        else if (c == "E") d = 14;
        else if (c == "F") d = 15;
        else continue;   # skip any stray whitespace/CR
        n = n * 16 + d;
    }
    return n;
}
