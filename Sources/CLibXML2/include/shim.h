// The slice of libxml2 AnimeGod uses: its forgiving HTML parser and XPath.
//
// A Kazumi-style source rule is five XPath expressions over a page some
// anime site serves, so running one needs an HTML parser that recovers from
// real-world markup and an XPath 1.0 engine. macOS has `XMLDocument` with
// `.documentTidyHTML`, which is exactly this library underneath — but
// `XMLDocument` does not exist on iOS (measured: `cannot find 'XMLDocument'
// in scope` against the iOS SDK), and AnimeGodCore builds for both. libxml2
// itself ships in every SDK, headers included, so going straight to it keeps
// the rule engine in the core where it can be tested, rather than splitting
// it across an `#if os(macOS)`.
//
// Declared through this header rather than hand-written like CLibArchive's,
// because node structs cross the boundary here and their layout is the
// library's to define.

#ifndef CLIBXML2_H
#define CLIBXML2_H

#include <libxml/HTMLparser.h>
#include <libxml/HTMLtree.h>
#include <libxml/xpath.h>
#include <libxml/xpathInternals.h>

// libxml2's deallocator is a global function *pointer*, and Swift 6 under
// `SWIFT_STRICT_CONCURRENCY: complete` refuses to reference one ("reference
// to var 'xmlFree' is not concurrency-safe because it involves shared
// mutable state"). Wrapping it means Swift calls a function instead.
static inline void ag_xml_free(void *pointer) {
    if (pointer != NULL) {
        xmlFree(pointer);
    }
}

#endif
