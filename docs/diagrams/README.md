# Architecture diagrams

`svsan-architecture.html` is the source of truth — a self-contained page that
opens straight from disk, no server and no network. Both SVGs are extracted from
it, so the page is the thing to edit.

| file | use |
|---|---|
| `svsan-architecture.html` | the full page — open in a browser, present from it |
| `svsan-architecture.svg` | the main figure, standalone, valid XML |
| `svsan-quorum.svg` | why the witness exists — `Up` vs `Majority` |
| `*.png` | 192 dpi raster for slide decks |
| `*.pdf` | vector for print or LaTeX |

Regenerate the SVG/PNG/PDF from the page after editing it:

```
make diagrams
```

Requires `inkscape` for the raster and PDF export.

## Fonts

Set in the Red Hat brand faces — Red Hat Display for headings, Red Hat Text for
prose, Red Hat Mono for every identifier, since IPs, MACs and device names *are*
identifiers. They are referenced by family name rather than embedded, so install
them or the page falls back to the system sans:

```
sudo dnf install redhat-display-fonts redhat-text-fonts redhat-mono-fonts
```

Or without root, which is how they were installed here:

```
dnf download redhat-display-fonts redhat-text-fonts redhat-mono-fonts
for r in *.rpm; do rpm2cpio "$r" | cpio -idm; done
mkdir -p ~/.local/share/fonts/redhat
find . -name '*.otf' -exec cp {} ~/.local/share/fonts/redhat/ \;
fc-cache -f ~/.local/share/fonts
```

## Palette

PatternFly, so it sits alongside other Red Hat material without looking foreign.
Colour is semantic, never decorative — each hue means exactly one thing:

| | |
|---|---|
| Red Hat Red `#EE0000` | RHEL host boundary |
| PatternFly Gold `#F0AB00` | StorMagic appliance |
| PatternFly Blue `#0066CC` | storage / mirror path |
| PatternFly Purple `#5752D1` | quorum |

## Reading the main figure

Storage rises bottom-up: NVMe -> LVM volume group -> logical volumes -> libvirt ->
VSA. The volume group is carved so Option A and Option B hold separate volumes
and can run on the same pair of machines without one disturbing the other.

Two things in it are easy to miss and are the reason it is drawn this way:

**The loop-back.** Each host runs an iSCSI initiator against a VSA hosted on
itself, drawn as the teal line down the outside of each host. That is why the
storage NIC must be a real bridge — a macvtap guest can reach every host except
the one it runs on, so the local path would silently never form.

**The witness is a container.** Drawn as a podman box inside a RHEL host next to
corosync-qnetd, rather than as an opaque appliance, because that is the finding:
it is StorMagic's own daemons on UBI9, deployable wherever there is podman.
