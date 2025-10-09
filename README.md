# Clad Builder

This is a fork of VSCodium, which has a nice build pipeline that we're using for Clad. Big thanks to the CodeStory and Void teams for inspiring this.

The purpose of this VSCodium fork is to run [Github Actions](https://github.com/clad-solutions/clad_builder_void/actions). These actions build all the Clad assets (.dmg, .zip, etc) and store these binaries on a release in [`clad-solutions/clad_ide_binaries`](https://github.com/clad-solutions/clad_ide_binaries/releases).

The `.patch` files from VSCodium get rid of telemetry in Clad (the core purpose of VSCodium) and change VSCode's auto-update logic so updates are checked against `clad` and not `vscode` (we just had to swap out a few URLs). These changes described by the `.patch` files are applied to `vscode/` during the workflow run, and they're almost entirely straight from VSCodium, minus a few renames to Clad.

## Notes

- For an extensive list of all the places we edited inside of this VSCodium fork, search "Clad" and "clad-solutions". We also deleted some workflows we're not using in this VSCodium fork (insider-* and stable-spearhead).

- The workflow that builds Clad for Mac is called `stable-macos.yml`. We added some comments so you can understand what's going on. Almost all the code is straight from VSCodium. The Linux and Windows files are very similar.

- If you want to build and compile Clad yourself, you just need to fork this repo and run the GitHub Workflows.

## Rebasing
- We often need to rebase `clad_ide_void` and `clad_builder_void` onto `vscode` and `vscodium` to keep our build pipeline working when deprecations happen, but this is pretty easy. All the changes we made in `clad_ide_void/` are commented with the caps-sensitive word "Clad" (except our images, which need to be done manually), so rebasing just involves copying the `vscode/` repo and searching "Clad" to re-make all our changes. The same exact thing holds for copying the `vscodium/` repo onto this repo and searching "Clad" and "clad-solutions" to keep our changes. Just make sure the vscode and vscodium versions align.
