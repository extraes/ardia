// Copyright 2026 Ardia. Apache-2.0.

#ifndef ARDIA_CORE_AC_CONTENTS_BACKGROUND_H_
#define ARDIA_CORE_AC_CONTENTS_BACKGROUND_H_

#include <optional>

#include "third_party/skia/include/core/SkColor.h"

namespace content {
class WebContents;
}

namespace ardiacore {

void SetContentsBackgroundColor(content::WebContents* contents, std::optional<SkColor> color);

std::optional<SkColor> ContentsBackgroundColor(content::WebContents* contents);

void SetHostPageBaseBackgroundColor(content::WebContents* contents, std::optional<SkColor> color);

void MarkAheadBlank(content::WebContents* contents);

void EndAheadBlank(content::WebContents* contents);

bool InAheadBlank(content::WebContents* contents);

}

#endif
