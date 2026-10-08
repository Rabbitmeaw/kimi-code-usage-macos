#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/checks
swiftc -parse-as-library -swift-version 5 \
  -module-cache-path .build/out/ModuleCache.noindex \
  Sources/KimiUsage/Models.swift \
  Sources/KimiUsage/QuotaClient.swift \
  Sources/KimiUsage/WindowGeometry.swift \
  Sources/KimiUsage/WindowStyleReader.swift \
  Sources/KimiUsage/QuotaBandSettings.swift \
  Sources/KimiUsage/EmojiCatalog.swift \
  Tests/CoreChecks.swift \
  -o .build/checks/core-checks
.build/checks/core-checks
