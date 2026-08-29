# Convert the Sun Gallant 12x22 BDF (illumos usr/src/data/consfonts/Gallant19.bdf,
# CDDL / Copyright 2006 Sun Microsystems) into a pure-Nix glyph table that draw.nix
# consumes. Every glyph in this BDF is a fixed 12x22 cell (uniform BBX 12 22 0 -5):
# 22 BITMAP rows, each a 4-hex-digit 16-bit word whose TOP 12 bits are the glyph
# columns (bit 15 = leftmost column x=0). We keep only the printable ASCII range
# 0x20..0x7e (all present) so the emitted Nix stays small and NUL-free.
#
# Output shape (row-major, one int per row, bit 11 = leftmost column):
#   {
#     glyphs = {
#       "48" = [ <22 ints> ];   # '0'
#       ...
#     };
#     width = 12; height = 22;
#   }
#
# Each row int r has bit (11-col) set when pixel (col,row) is lit, so draw.nix
# lights pixel (x+col, y+row) iff (r / 2^(11-col)) is odd. No NUL, ints only.
BEGIN {
    enc = -1; inbits = 0; nrows = 0;
    print "# GENERATED from Gallant19.bdf (Sun Gallant 12x22, CDDL). Do not edit.";
    print "# See LICENSE.gallant. width=12 height=22, row-major (bit 11 = leftmost col).";
    print "{";
    print "  width = 12;";
    print "  height = 22;";
    print "  glyphs = {";
}

/^ENCODING /    { enc = $2 + 0; next }
/^BITMAP/       { if (enc >= 32 && enc <= 126) { inbits = 1; nrows = 0; delete rows } next }
/^ENDCHAR/ {
    if (inbits && enc >= 32 && enc <= 126) {
        # Emit `"<enc>" = [ r0 r1 ... r21 ];`. Convert each 16-bit BDF word to the
        # 12-bit row: shift right by 4 so bit 11 = former bit 15 (leftmost col).
        line = "    \"" enc "\" = [";
        for (i = 0; i < nrows; i++) {
            w = hex2dec(rows[i]);
            row12 = int(w / 16);   # >> 4, keep the top 12 bits as a 12-bit value
            line = line " " row12;
        }
        line = line " ];";
        print line;
    }
    inbits = 0;
    next
}
{
    if (inbits) {
        # A BITMAP data row: a hex word (uppercase, 4 digits). Store verbatim.
        rows[nrows] = $0;
        nrows++;
    }
}

END {
    print "  };";
    print "}";
}

# Parse an uppercase (or mixed) hex string to a decimal integer (awk has no strtonum
# in POSIX mode). Handles the 4-digit BDF words.
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
