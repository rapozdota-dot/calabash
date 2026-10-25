---
version: alpha
name: Calabash Maturity Detection
description: A field-oriented Flutter app for visual calabash assessment using its existing green and cream identity.
colors:
  primary: "#2E7D32"
  background: "#F5F7F2"
  surface: "#FFFFFF"
  text: "#4E5B4D"
  supporting: "#687366"
  mature: "#388E3C"
  immature: "#FFA000"
  overmature: "#D32F2F"
typography:
  body:
    fontFamily: "Nunito Sans"
    fontSize: "16px"
    lineHeight: "24px"
  heading:
    fontFamily: "Nunito Sans"
    fontSize: "20px"
    lineHeight: "26px"
rounded:
  card: "8px"
  dialog: "22px"
  home-action: "12px"
spacing:
  page: "20px"
  result-page: "16px"
  card: "16px"
  compact-card: "14px"
  section: "14px"
  about-section: "24px"
components:
  information-button:
    iconSize: "22px"
    minimumTouchTarget: "48px"
  information-dialog:
    maxWidth: "520px"
    padding: "24px"
---

# Calabash Maturity Detection design system

## Overview

The existing agricultural branding, cream surfaces, fruit preview and result
cards are the visual reference. The English-language mobile interface serves
people visually assessing calabash and researchers reviewing predictions.
Offline field use calls for legible labels and familiar camera controls.
Preserve this product identity and the approved branded splash. Avoid decorative
motion, new navigation, or research findings inferred from appearance alone.

Runtime Dart values are canonical; this document mirrors them:

| Role | Runtime owner | Consumers / verification |
| --- | --- | --- |
| Palette, page/card spacing and radii | `lib/utils/constants.dart` | Screens/cards; model/camera values in this file remain protected |
| Type and theme | `lib/utils/app_theme.dart` | `main.dart`, screens, actual-theme widget tests |
| Help geometry, dialog shape, preview limits | `lib/utils/ui_tokens.dart` | Shared help, About, DetectionImage |
| Information affordance and label row | `lib/widgets/information_button.dart` | Home, results, live help |
| Modal help | `lib/widgets/information_dialog.dart` | Native AlertDialog and shared regressions |
| Scientific explanations | `lib/utils/prediction_explanations.dart` | About, results, live help |

## Colors

Keep primary green, cream backgrounds, and white cards. Orange, green and red
indicate Immature, Mature and Overmature, always accompanied by written labels.
Tinted cards use dark neutral text. Overlay labels use opaque class-color
backgrounds with black/white foreground selected for contrast. Mask colors and
pixels retain their existing meaning.

## Typography

Reuse bundled Nunito Sans; disable runtime font downloads. `headlineSmall` is
24sp semibold for page/primary prediction titles; `titleLarge` is 20sp semibold
for sections/dialogs; `titleMedium` is 16sp semibold for cards. Body roles are
16/14/12sp regular with 1.5 line height (1.4 for supporting text); controls use
15sp medium. Live overlays use supporting text. Text scales with accessibility
settings. Splash base sizes remain 32/14/12sp with its existing widget-specific
weights and composition.

## Layout

Keep existing Navigator/provider flows, SafeArea and scrolling. Single results
prioritize image, stage/score, guidance, limitations, then retry. Multiple results
prioritize image, counts, individual predictions, guidance, limitations, then
retry. The existing 700dp breakpoint retains two result columns. Previews preserve
source aspect ratio, fit within half the viewport height (maximum 420dp), and use
one rectangle for image and overlays. About keeps two cards with 24dp section and
8dp title/body gaps.

## Elevation & Depth

Cards use elevation 1, restrained tints, and explicit headings. Live camera chrome
retains its black background and scrims. Help surfaces use native modal depth.

## Shapes

Cards retain 8dp radii and Home actions 12dp. Information dialogs use 22dp corners,
24dp inset/padding, maximum 520dp width, and content-driven height with scrolling.

## Components

Outlined Material information icons are 22dp with 48dp minimum touch targets,
including landscape camera toolbars. Tooltips name the action. Label rows wrap
with the control next to the label. Fully visible external-assessment notices
use a decorative visibility icon rather than an apparent help button. Native
dialogs retain modal focus/dismissal and a green Close action. Capture-busy help
disabling preserves result navigation.

Keep native focus, pressed, disabled and hover states. Loading, empty, error and
successful-result states stay distinct. Existing reduced-motion and camera
animation policies remain. Explanations describe visual predictions and model
class scores without claiming measured accuracy, calibrated probabilities,
internal quality, safety, or guaranteed harvest readiness.

## Do's and Don'ts

- Use semantic theme roles and existing palette values.
- Verify narrow portrait/landscape, long copy and 2x text with the actual theme.
- Preserve mask pixels and coordinate mapping while fitting previews.
- Preserve the splash, camera processing, timing and result navigation.
- Avoid color-only labels, oversized fixed help containers, and duplicate dialogs.
