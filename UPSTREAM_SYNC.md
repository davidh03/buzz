# Keeping the Buzz fork current

This fork tracks `block/buzz` as the `upstream` remote. The checked-out repo is on the laptop at `~/Documents/GitHub/buzz`; AWS only pulls container images and deployment files and does not clone the source repo.

To review and bring upstream changes into the fork:

```sh
cd ~/Documents/GitHub/buzz
git checkout main
git fetch upstream main
git log --oneline --left-right main...upstream/main
git diff --stat main...upstream/main
git merge upstream/main
# Resolve and test any conflicts before deploying.
git push origin main
```

A successful push to the fork's `main` runs the existing `Docker image` workflow. When that completes successfully, `Deploy Buzz relay to EC2` waits for it and updates the isolated EC2 instance to the matching `sha-<7>` image. Feature branches and unmerged pull requests do not deploy.

The workflow is gated by the repository variable `BUZZ_DEPLOY_ENABLED=true`. Keep it false until the GHCR package `davidh03/buzz` is public and an initial deployment has been verified. Runtime secrets stay in `/opt/buzz/.env` on EC2; never commit `.env`, Nostr private keys, or storage credentials.
