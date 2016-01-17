// =============================================================================
// PROJECT CHRONO - http://projectchrono.org
//
// Copyright (c) 2014 projectchrono.org
// All right reserved.
//
// Use of this source code is governed by a BSD-style license that can be found
// in the LICENSE file at the top level of the distribution and at
// http://projectchrono.org/license-chrono.txt.
//
// =============================================================================
// Authors: Hammad Mazhar
// =============================================================================
//
// ChronoParallel unit test for MPR collision detection
// =============================================================================

#include <stdio.h>
#include <vector>
#include <cmath>

#include "unit_testing.h"
#include "chrono_parallel/math/other_types.h"

using namespace chrono;
int main(int argc, char* argv[]) {
    uint4 a = _make_uint4(1, 2, 3, 4);

    uint4 r = Sort(a);

    StrictEqual(a, r);
    uint4 b;
    b = _make_uint4(4, 3, 2, 1);
    r = Sort(b);
    StrictEqual(a, r);

    b = _make_uint4(4, 2, 3, 1);
    r = Sort(b);
    StrictEqual(a, r);

    b = _make_uint4(3, 4, 2, 1);
    r = Sort(b);
    StrictEqual(a, r);

    b = _make_uint4(1, 3, 2, 4);
    r = Sort(b);
    StrictEqual(a, r);

    return 0;
}
