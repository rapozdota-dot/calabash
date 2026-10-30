# Android V7 Model Performance Comparison

These are opt-in research builds, not replacements for the regular releases.
The Android APK workflow previously omitted CALABASH_PERF, disabling recording.
On `codex/android-performance-comparison`, the registered Android workflow is
configured as manual-only **Android Model Performance Comparison**. It always
passes CALABASH_PERF=true, records the exact model SHA-256 and source revision,
and builds both variants from the SAME application code. It does not build iOS.

## Install And Record

1. Install both APKs: **Calabash YOLO Perf** and **Calabash Hybrid Perf**.
   Their application IDs end in `.yoloperf` and `.hybridperf`; data is separate.
   They can coexist with the ordinary Calabash app. No uninstall is needed.
2. Open the chosen app. Home must say **Performance recording is enabled**,
   show the model variant, and display Live/Capture/Gallery recording counts.
3. Use the same physical phone, lighting, distance, images, camera orientation,
   and scanning method for both variants. Close the other variant while testing
   so two model runtimes do not compete for memory/CPU. Note thermal conditions.
4. Run Live Detection, Capture, and/or Gallery scans. Recording is automatic;
   this is not a Start/Stop benchmark and opening Home does not fabricate runs.
   Collect at least 30 valid non-warm-up observations per workflow per model.
   Use the same selection/order of original images. Report repetition versus
   unique-image counts honestly. A camera pointed at a screen is not identical
   to gallery inference on the source image.
   Report how many frames had no detected fruit; blank scenes can be faster than
   mask reconstruction on actual fruits and must not be silently mixed in.
5. Return Home and tap **Export Performance Data**. Save/send the ZIP using the
   Android share sheet. Unzip and open **performance_report.xlsx** in Excel or
   LibreOffice. Export EACH variant before force-closing it; a new process starts
   a new session. Source CSVs remain in app storage and are never overwritten by
   repeated exports; retain previously exported ZIPs to combine sessions later.

## Export Contents

- Summary: processing/inference/invoke averages, minimum/maximum, valid counts,
  exclusions, sampled percentiles, throughput and the existing requirement rule,
  separated by Live/Gallery/Capture. Blank means not measured, never zero.
- Raw Measurements: every recorded observation and available processing stage,
  model/backend configuration, timestamps, warm-up and inclusion/exclusion flags.
- Session: model variant/hash, source/build/session identifiers, device model,
  Android version, chipset where available, kernel-accessible RAM, and a single
  app PSS measurement at export. **Average application memory is not measured.**
- Original raw/summary CSVs, session_metadata.json, and READ_ME.txt retain the
  original records and identify the model without relying on the filename.

Excel is generated in a background isolate from the same serialized snapshots
as the CSV/metadata export. No extra logging or workbook generation is inserted
inside the timed model invocation. Statistics are existing app aggregates, not
invented examples or prepopulated manuscript measurements. Source workbook
text is exported as text, not executable Excel formulas.

## Timing Boundaries

- `interpreter_invoke_ms`: pure Interpreter.invoke(), excluding tensor copies.
- `yolo_inference_ms`: legacy inference boundary, input transfer + invoke + output
  transfer. The name is retained for CSV compatibility for BOTH architectures.
- Photo complete processing: analysis start through prepared result, including
  file read/decode, initialization when necessary, preprocessing and mask work.
  Camera shutter/gallery selection and final screen rendering are excluded.
- Live complete processing: accepted-frame processing through detections, with
  measured conversion/queue/transfer stages; excludes waiting for a camera frame
  and final screen rendering. Processed FPS is not camera preview FPS.
- Warm-up/error/invalid rows remain in raw data but are excluded where flagged.
  Completed stale/invalidated neural calls are NOT dropped from inference
  summaries merely because they were too slow for a useful overlay.
- Sampled percentiles use a maximum 4096-entry nearest-rank reservoir per method.
  The existing PASS rule requires at least 30 valid measured durations and all
  applicable durations <=3000 ms; NOT_ENOUGH_DATA is not a passing result.

Do not average workflow averages to claim an overall result. If needed, combine
the raw eligible rows and compute a count-weighted overall mean. Do not compare
different timing columns or silently exclude slow runs. Detection correctness
is separate from processing performance; this build does not fix false positives.

Android device fields use the platform's documented memory APIs:
[MemoryInfo.totalMem](https://developer.android.com/reference/android/app/ActivityManager.MemoryInfo#totalMem)
and [Debug.MemoryInfo](https://developer.android.com/reference/android/os/Debug.MemoryInfo).
Kernel-accessible RAM can differ from the phone's marketed RAM capacity.
