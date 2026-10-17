# Infrastructure

How this fork of stunserver is deployed. The CloudFormation templates and the list
of regions live here; the pipeline that uses them is in `.github/workflows`, with
its scripts in `.github/scripts`.

| File | What it is | Deployed by |
|---|---|---|
| `bootstrap.yaml` | One-time foundations: the package registry credential (a secret, replicated to every region) and the role the pipeline assumes | A maintainer, by hand. The pipeline never changes it |
| `service.yaml` | The server itself: one stack per region, managed as a CloudFormation StackSet | The release pipeline |
| `regions.json` | The regions the server runs in | Applied by the release pipeline |

## Why bootstrap is separate

The pipeline's own permissions are defined in `bootstrap.yaml`. Keeping that file out
of the pipeline means a release cannot change what it is allowed to do. After editing
it, a maintainer deploys it by hand. The secret's value is entered by hand in the
primary region and replicated from there; it is never in this repository.

## Releasing

1. Merge your changes to `master` through a reviewed pull request.
2. A maintainer pushes a tag of the form `vX.Y.Z`. The tag is the version.
3. The workflow builds the package and publishes it to the private package registry.
   It then shows the reviewers what the release changes: the changelog since the last
   release, any change to `service.yaml`, and any change to the regions.
4. The reviewers of the `production` environment approve.
5. Regions are updated one at a time, and the first failure stops the rollout. The
   workflow then checks that every region runs the new version and answers requests.
6. Only after all of that is a GitHub release created, with the changelog. A tag
   without a release means its deploy did not complete.

Only tags (and the manual rollback below) can deploy. Pull requests and forks cannot.

**Never reuse a version.** Its package was already published when the build ran. If a
deploy fails or is rejected, fix the problem and tag the next version; the next
changelog still starts from the last release, so nothing is skipped.

## Adding or removing a region

The regions are listed in `regions.json`.

**To add a region**

1. Add it to the secret's `ReplicaRegions` in `bootstrap.yaml` and deploy that file by
   hand, so the secret exists in the new region before any server does.
2. Add the region to `regions.json` and merge.
3. Release as above.

The pipeline checks this before anyone is asked to approve: a region in
`regions.json` with no replica in `bootstrap.yaml` fails the run. It checks again in
AWS before it creates the region. Some AWS regions must be enabled for the account
first.

**To remove a region**

1. Remove it from `regions.json` and merge, then release.
2. Optionally remove its replica from `bootstrap.yaml` afterwards and redeploy by hand.

The approval summary lists regions being added or removed. Removing a region deletes
the server there. Only a region removed in that release's own change can be deleted;
any other difference between the file and what is deployed stops the deploy.

## Rolling back

Run the **Rollback** workflow from `master` (Actions tab) with the version to restore,
for example `1.2.20`. It goes through the same approval and the same checks as a
release. It redeploys that release's package and its `service.yaml`, and it does not
add or remove regions.

Only versions that have a GitHub release can be rolled back to, so releases from
before this pipeline existed cannot. The base operating system image is chosen at
deploy time, so a rollback also moves to the current image.

## Checking a change before you open a pull request

```
cfn-lint infra/*.yaml
```
