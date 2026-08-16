package ask

import "github.com/denysvitali/dc-1-pmos/installer/gotools/internal/textfont"

// textW is the width of str at scale s, measured from the shared anti-aliased
// face so keyboard, button centring and the entry caret track what is actually
// drawn.
func textW(s int, str string) int { return textfont.Measure(s, str) }

// fitScale steps the glyph scale down until label fits maxW pixels, but no
// further than floor.
func fitScale(s, floor int, label string, maxW int) int {
	for s > floor && textW(s, label) > maxW {
		s--
	}
	return s
}
