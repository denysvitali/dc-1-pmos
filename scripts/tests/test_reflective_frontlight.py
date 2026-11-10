#!/usr/bin/env python3
"""Compile the input transformation from the shipped GSD patch, not a copy."""
from pathlib import Path
import os
import subprocess
import tempfile

patch = (Path(__file__).resolve().parents[2] /
         'pmaports/device/testing/gnome-settings-daemon-mobile/reflective-frontlight.patch')
# Reconstruct the patched hunk, then compile the policy with a minimal settings stub.
lines = patch.read_text().splitlines()
body = '\n'.join(line[1:] for line in lines
                 if line.startswith((' ', '+')) and not line.startswith('+++'))
start = body.index('        ambient_last_absolute = g_variant_get_double (val_als);')
end = body.index('        g_debug ("Read absolute light level:', start)
policy = body[start:end].replace('g_variant_get_double (val_als)', 'input')
policy = policy.replace('g_settings_get_boolean (manager->settings, "ambient-inverted")', 'inverted')
source = r'''
#include <assert.h>
#include <math.h>
#include <float.h>
static double output;
static void transform(double input, int inverted) {
    double ambient_last_absolute;
POLICY
    output = ambient_last_absolute;
}
static double apply(double input, int inverted) {
    output = -1;
    transform(input, inverted);
    return output;
}
int main(void) {
    const double readings[] = {0, 1, 100, 640, 4096, 65535, DBL_MAX};
    double previous = 2;
    for (unsigned i = 0; i < sizeof(readings)/sizeof(readings[0]); i++) {
        double result = apply(readings[i], 1);
        assert(isfinite(result) && result > 0 && result < previous);
        previous = result;
        if (readings[i] > 0)
            assert(apply(readings[i], 0) == readings[i]);
    }
    assert(apply(0, 1) == 1);
    assert(apply(0, 0) == -1);
    for (int inverted = 0; inverted < 2; inverted++) {
        assert(apply(-1, inverted) == -1);
        assert(apply(NAN, inverted) == -1);
        assert(apply(INFINITY, inverted) == -1);
        assert(apply(-INFINITY, inverted) == -1);
    }
    // Fixed native normalization retains direction and bounds for both policies.
    double baseline = apply(640, 1);
    assert(apply(100, 1) / baseline > 1);
    assert(apply(4096, 1) / baseline < 1);
    return 0;
}
'''.replace('POLICY', policy)
with tempfile.TemporaryDirectory() as temp:
    path = Path(temp)
    (path / 'test.c').write_text(source)
    subprocess.run([os.environ.get('CC', 'cc'), '-std=c11', '-Wall', '-Wextra',
                    '-Werror', str(path / 'test.c'), '-o', str(path / 'test')], check=True)
    subprocess.run([str(path / 'test')], check=True)
print('Reflective input policy: dark, bright, zero, extreme and invalid readings passed')
