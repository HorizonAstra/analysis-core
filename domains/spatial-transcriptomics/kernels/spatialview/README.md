# What SpatialView Does With A Bundle

Notes on the third-party viewer, written down because they decide how bundles
should be built and none of it is visible from our side of the boundary.

## It Loads Every Sample At Once

Its loader walks the sample list and, for each sample, fetches the tissue image,
the metadata, the scale factors, the sample description and the sparse
expression matrix. There is no deferring and no loading on selection. Opening a
bundle means loading all of it.

`static/js/application_script.js`, the loop from around line 169.

So the bundle is the unit of scale, not the study and not the cohort. Samples
that are in one bundle are in memory together, and samples in different bundles
cannot be compared, because its cross-sample views only reach what it loaded.

## Measured Sizes

One sample of this cohort, nine files:

    expression_matrix_sparse.txt   50 MB
    tissue_hires_image.png          5 MB
    everything else               under 1 MB
    total per sample               54 MB

Nineteen samples is about 1 GB in the browser at open. That is heavy and works.
A hundred and fifty samples is not something to attempt.

If a study outgrows this, the answer is smaller bundles chosen for a question
rather than one bundle holding everything, and the cost of that is that samples
in different bundles can no longer be compared. There is no setting to change.

## Where It Runs

The files are served by the web app, so the memory cost above is the browser's
and the storage cost is the machine running the app. In development that is a
laptop. A deployment wants a workstation or a cluster node held outside the job
scheduler, since the app is a long-lived process and not a job.

## It Cannot Be Modified

Its licence is academic and does not permit modifying or redistributing it, so
everything above is a constraint to design around rather than a bug to fix. Two
consequences worth knowing:

* Its page is taller than a normal viewport, so the frame it sits in scrolls.
  That is the viewer's own layout.
* It reads its colour scale images from an external address, so those do not
  appear on a machine with no route to the internet. Nothing else about it
  depends on being online.

Our own integration is described in `clients/webapp/viewer.py`, which mounts it
over one run's bundle and checks who is asking.
