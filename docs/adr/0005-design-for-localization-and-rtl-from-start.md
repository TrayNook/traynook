---
status: accepted
---

# Design for localization and RTL from the first release

TrayNook 1.0.0 bundles US English only, but every user-facing string uses platform localization resources and every layout supports expansion, bidirectional text, and right-to-left mirroring from the start. The project avoids concatenated sentences, gives translators context and placeholder guidance, tests pseudolocalization plus a pseudolanguage in RTL mode, and maintains a root-level translation guide. This incurs a small first-release discipline cost to avoid an expensive UI and string-model retrofit when community translations arrive.
