## ADDED Requirements

### Requirement: Select an image from the local filesystem
The application SHALL provide a UI action that opens a native file-selection
dialog and imports an accepted selected image.

#### Scenario: Successful image selection

- **WHEN** a user selects a supported image file and confirms the dialog
- **THEN** the image is imported through the application import boundary

### Requirement: Show newly imported images
The application SHALL show a successfully imported image in the image strip
without requiring a full application restart.

#### Scenario: Import completes

- **WHEN** an image import completes successfully
- **THEN** the image strip refreshes to include the imported image
