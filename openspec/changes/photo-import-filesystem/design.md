# Design

The UI action opens the platform file-selection interface. The import boundary
validates supported image formats, persists successful images, and emits an
import-complete event. The image strip subscribes to that event and refreshes.

Open decision for Product Owner: whether the first version permits selecting
multiple files. This example defaults to one file until explicitly changed.
