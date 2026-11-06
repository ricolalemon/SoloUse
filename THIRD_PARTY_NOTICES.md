# Third-party notices

The top-level MIT license covers first-party work except files explicitly marked otherwise. It does not replace upstream licenses. This source candidate contains no prebuilt third-party or Apple framework binaries.

| Component | Pinned source | License / retained notice | Scope |
| --- | --- | --- | --- |
| idevice | `jkcoxson/idevice`, revision `d32c8189c51c2789496b0768039419c3705498c3` | MIT; [notice](Licenses/idevice-MIT.txt), [vendored license](Native/vendor/idevice/LICENSE) | Native protocol library; vendored source includes local XCTest/RSD diagnostics changes |
| QuickJS-NG | v0.17.0 | MIT; [license](Native/QuickJS/LICENSE), [source hashes](Native/QuickJS/SOURCE.json) | Interpreter; four C sources are compiled; libc/OS bindings are not exposed |
| OpenAI Codex | revision `d3e584093222018fc27919403aea149ccfd3bb38` | Apache-2.0; [license](Licenses/codex-Apache-2.0.txt), [NOTICE](NOTICE) | Authentication/request and compaction protocol adaptations, rewritten in Swift; adapted files carry notices |
| Device Hub iOS | architecture/protocol reference | MIT; [notice](Licenses/device-hub-ios-MIT.txt) | Reference for device-side developer-service operation; not a bundled app |
| Appium WebDriverAgent | active-application API sequence reference | BSD; [notice](Licenses/WebDriverAgent-BSD.txt) | Optional read-only XCTest snapshot companion; no WDA server is embedded |

The vendored idevice modification list is [SOLOUSE_CHANGES.json](Native/vendor/idevice/SOLOUSE_CHANGES.json). Its license and README were copied from the upstream repository root; the two modified source files adapt authenticated RSD startup and stage reporting. Their upstream headers remain intact.

## Locked Rust graph

[Complete inventory](Licenses/CARGO_DEPENDENCIES.md) · [Machine-readable evidence](Licenses/cargo-inventory.json)

The inventory covers 189 third-party packages in the current all-platform locked dependency graph, including 152 in the iOS-resolved graph (build dependencies included). It records original license expressions, a selected option where appropriate, repository/revision metadata, and hashes of retained notice files. The Rust root package is first-party and is not counted as a third-party dependency.

Two crates (`ns-keyed-archive 0.1.5`, `plist-macro 0.1.6`) declare `MIT OR Apache-2.0` but do not ship a standalone license file. Their original Cargo declarations are retained. Standard MIT text is supplied for the declared MIT option, with metadata authorship attribution; it is explicitly not presented as an upstream license file or an inferred copyright year. This provenance gap is listed in the inventory and release audit.

`r-efi` lists an LGPL alternative alongside MIT/Apache; this distribution records the MIT option and retains its original AUTHORS license text. `unicode-ident` also requires Unicode-3.0; that notice is retained. `ring` has Apache-2.0/ISC and nested upstream notices; those are included rather than reduced to one generic label. No mandatory GPL/AGPL/LGPL-only package was found in this resolved graph. Changing features, targets or dependency versions requires a fresh review.

`Scripts/collect-licenses.py` regenerates the inventory from `cargo metadata --locked`. It is an engineering inventory, not a legal opinion or a grant beyond the upstream terms. Before distributing compiled apps, include the applicable notices with the binary distribution and review any new components. Rust toolchain and Apple SDK components are installed by the builder and are not included in this source archive.

## External services and applications

LocalDevVPN is installed separately; its implementation/binary is not redistributed here. Xcode, iOS SDKs and developer disk images come from Apple's tooling; none are bundled. OpenAI authentication/backend access is governed separately from code licensing. The Apache license on Codex source is not a general authorization to redistribute credentials or access a subscription backend.

Apple, iPhone, iOS, Xcode and macOS are Apple trademarks. SoloUse is independent of Apple and OpenAI and is not endorsed by either.
