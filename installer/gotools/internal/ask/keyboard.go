package ask

// On-screen keyboard: layout, geometry and hit-testing. Pure functions over
// plain values so the offline tests can drive them without a panel.

// Special key codes (never printable ASCII).
const (
	keyNone  = 0
	keyShift = 1
	keySym   = 2
	keyBS    = 3
	keyOK    = 4
)

// Layer rows: 10 cells each for rows 0..3; row 4 is fixed special. The
// \x01..\x03 bytes are the special codes above embedded where the C tool had
// them, so the hit-testing and drawing see one uniform grid.
var (
	rowsLower = []string{"1234567890", "qwertyuiop", "asdfghjkl-", "\x01zxcvbnm.\x03"}
	rowsUpper = []string{"1234567890", "QWERTYUIOP", "ASDFGHJKL-", "\x01ZXCVBNM.\x03"}
	rowsSym   = []string{"1234567890", "!@#$%^&*()", "-_=+[]{};:", "\x02'\",<>/?\\\x03"}
	// note: rowsSym[3] has 9 cells + backspace = 10
)

func kbRows(layer, shifted int) []string {
	if layer != 0 {
		return rowsSym
	}
	if shifted != 0 {
		return rowsUpper
	}
	return rowsLower
}

// kbGeom is where the keyboard sits on the panel and how big one key cell is.
type kbGeom struct {
	top, cellW, cellH int
}

func kbGeometry(w, h int) kbGeom {
	cellH := h / 11
	return kbGeom{top: h - 5*cellH, cellW: w / 10, cellH: cellH}
}

// kbHit maps a tap to a key: a printable byte, or a key* code.
func kbHit(g kbGeom, layer, shifted, x, y int) int {
	if y < g.top {
		return keyNone
	}
	r := (y - g.top) / g.cellH
	c := x / g.cellW
	if c > 9 {
		c = 9
	}
	if r < 4 {
		row := kbRows(layer, shifted)[r]
		if c >= len(row) {
			return keyNone
		}
		return int(row[c])
	}
	// row 4: [SYM/ABC x2][SPACE x5][@ or ~ x1][OK x2]
	if c < 2 {
		return keySym
	}
	if c < 7 {
		return ' '
	}
	if c < 8 {
		if layer != 0 {
			return '~'
		}
		return '@'
	}
	return keyOK
}

func (c *canvas) drawKeyboard(g kbGeom, layer, shifted int) {
	rows := kbRows(layer, shifted)

	c.fillRect(0, g.top, c.w, 5*g.cellH, cBG)
	for r := 0; r < 4; r++ {
		y := g.top + r*g.cellH
		row := rows[r]
		for col := 0; col < len(row) && col < 10; col++ {
			x := col * g.cellW
			switch row[col] {
			case keyShift:
				bg := uint32(cBox)
				if shifted != 0 {
					bg = cShiftOn
				}
				c.drawKey(x, y, g.cellW, g.cellH, bg, "SH")
			case keySym:
				c.drawKey(x, y, g.cellW, g.cellH, cBox, "AB")
			case keyBS:
				c.drawKey(x, y, g.cellW, g.cellH, cBox, "<X")
			default:
				c.drawKey(x, y, g.cellW, g.cellH, cKey, string(row[col]))
			}
		}
	}
	// row 4: [SYM/ABC x2][SPACE x5][@ or ~ x1][OK x2]
	y := g.top + 4*g.cellH
	abc := "?123"
	if layer != 0 {
		abc = "abc"
	}
	at := "@"
	if layer != 0 {
		at = "~"
	}
	c.drawKey(0, y, 2*g.cellW, g.cellH, cBox, abc)
	c.drawKey(2*g.cellW, y, 5*g.cellW, g.cellH, cKey, " ")
	c.drawKey(7*g.cellW, y, g.cellW, g.cellH, cKey, at)
	c.drawKey(8*g.cellW, y, 2*g.cellW, g.cellH, cOK, "OK")
}

func (c *canvas) drawKey(x, y, w, h int, bg uint32, label string) {
	c.fillRect(x+4, y+4, w-8, h-8, bg)
	s := fitScale(4, 1, label, w-16)
	c.drawText(x+(w-textW(s, label))/2, y+(h-7*s)/2, s, cKeyTxt, label)
}
