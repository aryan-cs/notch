//
//  DropInteractionState.swift
//  boringNotch
//

import Observation

@Observable
final class DropInteractionState {
    var dragDetectorTargeting = false
    var generalDropTargeting = false
    var dropZoneTargeting = false
    /// The shelf's drop-action row (Convert, Zip, …) is under the drag.
    var actionTargeting = false
    var dropEvent = false

    var anyDropZoneTargeting: Bool {
        dragDetectorTargeting || generalDropTargeting || dropZoneTargeting || actionTargeting
    }
}
