 # Supported NixOS Template Workflow

 This repo supports one template path for future LXC creation:

 1. Build the template artifact from `nixos/` or another NixOS-capable build environment with
    `nixos-rebuild build-image --image-variant proxmox-lxc`.
 2. Upload or otherwise register the resulting artifact in Proxmox storage with content type `vztmpl`.
 3. Record the provider-consumable Proxmox file ID for that artifact.
 4. Pass that file ID into Terraform through `template_file_id`, which later plans will map to
    `operating_system.template_file_id`.

 ## What This Repo Expects

 - The template artifact already exists in Proxmox storage, or a later Terraform phase will create it
   through a supported download/upload resource.
 - The artifact is NixOS-capable and built for the `proxmox-lxc` workflow.
 - Terraform consumes the Proxmox file ID, not an ad hoc filename guess.

 ## Explicitly Rejected

 - Guest bootstrap provisioners such as `remote-exec` or `file`
 - Archived `nixos-generators` as the primary path
 - Telmate-specific examples or provider assumptions
