#!/usr/bin/env python3
"""Offline checks for the Astro build; run from any working directory."""

from functools import cache
from html.parser import HTMLParser
import hashlib
import json
from pathlib import Path
import re
import struct
from urllib.parse import unquote, urlsplit


ROOT = Path(__file__).resolve().parent / "dist"
SITE = "https://traynook.mahenzon.ru"
assert (ROOT / "index.html").is_file(), "Build missing: run npm run build inside website/ first"
assert (ROOT / "CNAME").read_text(encoding="utf-8").strip() == urlsplit(SITE).hostname, "Incorrect Pages custom domain"
assert (ROOT / ".nojekyll").is_file(), "Missing Pages marker for Astro assets"


class Page(HTMLParser):
    def __init__(self, path):
        super().__init__(convert_charrefs=True)
        self.path = path
        self.elements = []
        self.title = ""
        self.in_title = False
        self.install_commands = {}
        self.install_code_id = None
        self.feed(path.read_text(encoding="utf-8"))
        self.ids = [attrs["id"] for _, attrs in self.elements if "id" in attrs]

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        self.elements.append((tag, attrs))
        if tag == "title":
            self.in_title = True
        if tag == "code" and attrs.get("id") in ("demo-install-command", "faq-install-command"):
            self.install_code_id = attrs["id"]
            self.install_commands[self.install_code_id] = ""

    def handle_endtag(self, tag):
        if tag == "title":
            self.in_title = False
        if tag == "code":
            self.install_code_id = None

    def handle_data(self, data):
        if self.in_title:
            self.title += data
        if self.install_code_id:
            self.install_commands[self.install_code_id] += data


@cache
def read_page(path):
    return Page(path)


def check_reference(value, source):
    url = urlsplit(value)
    if (url.scheme or url.netloc) and f"{url.scheme}://{url.netloc}" != SITE:
        return None
    path = unquote(url.path)
    target = ((ROOT / path.lstrip("/")) if path.startswith("/")
              else (source.parent / path) if path else source).resolve()
    assert target.is_relative_to(ROOT), f"Local URL leaves build directory: {value}"
    if target.is_dir():
        target /= "index.html"
    assert target.is_file(), f"{source.relative_to(ROOT)}: missing local target {value}"
    if url.fragment:
        assert unquote(url.fragment) in read_page(target).ids, f"Missing anchor: {value}"
    return target


def png_dimensions(path):
    png = path.read_bytes()
    assert png[:8] == b"\x89PNG\r\n\x1a\n" and png[12:16] == b"IHDR", f"Not a PNG: {path}"
    return struct.unpack(">II", png[16:24])


def check_page(path, locale):
    assert path.is_file(), f"Missing built page: {path.relative_to(ROOT)}; rebuild website/"
    page = read_page(path)
    ids = page.ids
    assert len(ids) == len(set(ids)) and all(ids), f"{path}: duplicate or empty HTML IDs"
    assert sum(tag == "h1" for tag, _ in page.elements) == 1, f"{path}: expected one H1"
    html = next(attrs for tag, attrs in page.elements if tag == "html")
    assert html.get("lang") == locale, f"{path}: expected html lang={locale}"
    assert bool(html.get("data-detect-language")) == (path == ROOT / "index.html"), "Language detection belongs only on the root page"
    assert page.title.strip(), f"{path}: missing page title"
    metadata = {attrs.get("name", attrs.get("property")): attrs.get("content", "")
                for tag, attrs in page.elements if tag == "meta"}
    for key in ("description", "og:type", "og:site_name", "og:url", "og:title", "og:description",
                "og:locale", "og:image", "og:image:alt", "twitter:card", "twitter:title",
                "twitter:description", "twitter:image", "twitter:image:alt"):
        assert metadata.get(key, "").strip(), f"{path}: missing metadata {key}"
    assert metadata["twitter:card"] == "summary_large_image", "Expected large social card"
    assert metadata["og:locale"].split("_")[0] == locale, "Wrong social card locale"
    expected_url = f"{SITE}/{path.relative_to(ROOT).as_posix().removesuffix('index.html')}"
    canonical = [attrs.get("href") for tag, attrs in page.elements
                 if tag == "link" and "canonical" in attrs.get("rel", "").split()]
    assert canonical == [expected_url], f"{path}: incorrect canonical URL"
    assert metadata["og:url"] == expected_url, f"{path}: incorrect Open Graph URL"
    assert any(tag == "link" and "icon" in attrs.get("rel", "").split()
               and attrs.get("href") for tag, attrs in page.elements), f"{path}: missing favicon"

    for tag, attrs in page.elements:
        for name in ("href", "src"):
            if name in attrs:
                assert attrs[name], f"{path}: empty {name} on {tag}"
                check_reference(attrs[name], path)
        for candidate in attrs.get("srcset", "").split(","):
            if candidate.strip():
                check_reference(candidate.split()[0], path)
        for name in ("aria-labelledby", "aria-describedby", "aria-controls"):
            for reference in attrs.get(name, "").split():
                assert reference in ids, f"{path}: missing {name} target {reference}"
        if tag == "label" and "for" in attrs:
            assert attrs["for"] in ids, f"{path}: missing label target {attrs['for']}"
        if tag == "img":
            assert "alt" in attrs, f"{path}: missing image alt {attrs.get('src')}"
            assert all(attrs.get(size, "").isdigit() and int(attrs[size]) > 0
                       for size in ("width", "height")), f"{path}: missing image dimensions {attrs.get('src')}"

    alternate_urls = {attrs.get("hreflang"): attrs["href"]
                      for tag, attrs in page.elements
                      if tag == "link" and "alternate" in attrs.get("rel", "").split()}
    assert alternate_urls == {"en": f"{SITE}/en/", "ru": f"{SITE}/ru/",
                              "x-default": f"{SITE}/"}, f"{path}: incorrect absolute hreflang URLs"
    alternates = {language: check_reference(url, path) for language, url in alternate_urls.items()}
    assert alternates == {"en": ROOT / "en/index.html", "ru": ROOT / "ru/index.html",
                          "x-default": ROOT / "index.html"}, f"{path}: incorrect hreflang routes"
    languages = {attrs.get("hreflang"): attrs for tag, attrs in page.elements
                 if tag == "a" and attrs.get("hreflang") in ("en", "ru")}
    assert set(languages) == {"en", "ru"}, f"{path}: missing language links"
    for language, attrs in languages.items():
        assert attrs.get("lang") == language, "Incorrect language-link lang attribute"
        assert check_reference(attrs["href"], path) == ROOT / language / "index.html", "Incorrect language-link route"
        assert attrs.get("aria-current") == ("page" if language == locale else None), "Incorrect active language"

    dark_style = next(attrs for tag, attrs in page.elements if attrs.get("id") == "dark-theme")
    assert dark_style.get("media") == "(prefers-color-scheme: dark)", "Theme must default to system preference"
    assert check_reference(dark_style["href"], path).suffix == ".css", "Missing dark stylesheet"
    assert any(tag == "select" and attrs.get("id") == "theme-select" for tag, attrs in page.elements), "Missing theme selector"
    assert any(tag == "label" and attrs.get("for") == "theme-select" for tag, attrs in page.elements), "Theme selector needs a label"
    assert {attrs.get("value") for tag, attrs in page.elements if tag == "option"} == {"auto", "light", "dark"}, "Incorrect theme choices"

    expected_native = {f"/assets/native-ui/{view}-{theme}.png": (view, theme, dimensions)
                       for view, dimensions in (("settings", (1640, 1356)), ("dropdown", (784, 248)))
                       for theme in ("light", "dark")}
    native_links = {attrs["href"]: attrs for tag, attrs in page.elements
                    if tag == "a" and "data-native-capture" in attrs}
    assert native_links.keys() == expected_native.keys(), "Missing full-size native UI links"
    native_images = {attrs["src"]: attrs for tag, attrs in page.elements
                     if tag == "img" and "/assets/native-ui/" in attrs.get("src", "")}
    assert native_images.keys() == expected_native.keys(), "Missing paired native UI images"
    for url, (view, theme, dimensions) in expected_native.items():
        link, image = native_links[url], native_images[url]
        assert link.get("data-native-capture") == view and link.get("aria-label"), "Native image links need accessible view labels"
        assert f"native-{theme}" in link.get("class", "").split(), "Native image is missing its theme class"
        assert png_dimensions(check_reference(url, path)) == dimensions, f"Incorrect native PNG dimensions: {url}"
        assert tuple(int(image[size]) for size in ("width", "height")) == dimensions, f"Native image dimensions do not match: {url}"
        assert image.get("alt", "").strip(), f"Native image needs descriptive alt text: {url}"
    assert not {"interactive-demo", "demo-copy", "native-settings", "try-layout"}.intersection(ids), "Remove the recreated interface"
    assert "native-caption" in ids, "Describe the native images and sample data"

    github = next(attrs for tag, attrs in page.elements if "header-github" in attrs.get("class", "").split())
    assert github.get("href") == "https://github.com/TrayNook/traynook" and github.get("aria-label"), "Missing accessible header GitHub link"
    assert {attrs["data-repo-count"] for _, attrs in page.elements if "data-repo-count" in attrs} == {"stars", "forks"}, "Missing repository counters"
    for name, suffix in (("stars", ""), ("forks", "/forks")):
        assert any(tag == "a" and attrs.get("data-repo-link") == name and attrs.get("href") == f"https://github.com/TrayNook/traynook{suffix}" for tag, attrs in page.elements), f"Missing {name} link"

    expected_commands = {name: "brew tap traynook/tap\nbrew install traynook"
                         for name in ("demo-install-command", "faq-install-command")}
    assert page.install_commands == expected_commands, "Incorrect Homebrew commands"
    assert {attrs.get("aria-controls") for tag, attrs in page.elements
            if tag == "button" and "data-copy-command" in attrs} == set(expected_commands), "Missing Homebrew copy controls"
    assert all(attrs.get("aria-label") and attrs.get("title") for _, attrs in page.elements
               if "data-copy-command" in attrs), "Copy icons need accessible labels"
    assert sum("data-copy-feedback" in attrs and attrs.get("role") == "status" and "visually-hidden" in attrs.get("class", "").split()
               for _, attrs in page.elements) == 2, "Missing copy feedback"
    assert ids.index("native-caption") < ids.index("demo-install-command") < ids.index("how-it-works"), "Keep Homebrew installation immediately below native images"

    assert metadata["twitter:image"] == metadata["og:image"], "Social images differ"
    expected_image = f"{SITE}/assets/social-card{'-ru' if locale == 'ru' else ''}.png"
    assert metadata["og:image"] == expected_image, f"{path}: incorrect absolute social image URL"
    image = check_reference(metadata["og:image"], path)
    assert image is not None, "Social image must resolve to a bundled asset"
    dimensions = png_dimensions(image)
    assert dimensions == (1200, 630), f"Unexpected social image dimensions: {dimensions}"
    assert dimensions == tuple(int(metadata[f"og:image:{size}"]) for size in ("width", "height")), "OG dimensions do not match image"
    return image


results = {locale: check_page(ROOT / route, locale)
           for route, locale in (("index.html", "en"), ("en/index.html", "en"), ("ru/index.html", "ru"))}
assert results["en"] != results["ru"], "Use separate localized social cards"
native_dir = ROOT / "assets/native-ui"
provenance = json.loads((native_dir / "provenance.json").read_text(encoding="utf-8"))
assert {entry["file"] for entry in provenance["images"]} == {
    f"{view}-{theme}.png" for view in ("settings", "dropdown") for theme in ("light", "dark")
}, "Native provenance must cover all four rendered images"
for entry in provenance["images"]:
    image = native_dir / entry["file"]
    assert hashlib.sha256(image.read_bytes()).hexdigest() == entry["sha256"], f"Native image differs from render provenance: {image.name}"
    assert png_dimensions(image) == (entry["pixelWidth"], entry["pixelHeight"]), "Native provenance dimensions differ"
for script in ROOT.rglob("*.js"):
    assert not any(selector in script.read_text(encoding="utf-8") for selector in
                   ("interactive-demo", "demo-copy", "try-layout", "demo-announcement")), "Remove recreated UI scripts from the build"
for css in ROOT.rglob("*.css"):
    content = css.read_text(encoding="utf-8")
    references = re.findall(r"url\(\s*['\"]?([^'\")]+)['\"]?\s*\)", content)
    references += re.findall(r"@import\s+['\"]([^'\"]+)['\"]", content)
    for value in references:
        check_reference(value.strip(), css)
print("Passed: 3 built pages, 4 native PNGs and full-size links, no recreated interface, custom domain, local links/assets, accessibility references, canonical/social metadata, EN/RU routes, theme controls, GitHub widgets, and Homebrew commands.")
