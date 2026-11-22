import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Shared cover-import state machine for `ItemEditorSheet` and `CoverPickerSheet`.
/// Handles cancellation safety, race guards on drops, and temp-file staging/cleanup.
@MainActor
@Observable
final class CoverImportController {
    var coverFileName: String?
    var isLoading = false
    var errorMessage: String?
    var isDropTargeted = false

    @ObservationIgnored private var preservedFileName: String?
    @ObservationIgnored private var temporaryFiles: [String] = []
    @ObservationIgnored private var importTask: Task<Void, Never>?
    @ObservationIgnored private var dropID: UUID?

    init(initialCoverFileName: String? = nil) {
        self.coverFileName = initialCoverFileName
        self.preservedFileName = initialCoverFileName
    }

    func resetInitialCover(_ fileName: String?) {
        coverFileName = fileName
        preservedFileName = fileName
    }

    func stageTemporaryCover(_ fileName: String) {
        temporaryFiles.append(fileName)
        coverFileName = fileName
    }

    func resetToDefaultCover() {
        cancelImport()
        coverFileName = nil
        errorMessage = nil
    }

    func cancelImport() {
        importTask?.cancel()
        importTask = nil
        dropID = nil
        isLoading = false
    }

    func chooseLocalImage(language: AppLanguage, onWillStart: (() -> Void)? = nil) {
        errorMessage = nil
        if let url = CoverManager.shared.chooseLocalImagePanel(lang: language) {
            onWillStart?()
            importCover(.file(url))
        }
    }

    @discardableResult
    func pasteFromClipboard(
        language: AppLanguage,
        onWillStart: ((CoverSource) -> Void)? = nil,
        onSuccess: ((String) -> Void)? = nil
    ) -> Bool {
        guard let source = CoverManager.shared.inspectPasteboard() else {
            errorMessage = language.tr("剪贴板中没有检测到图片或图片链接", "No image or image URL in clipboard")
            return false
        }
        onWillStart?(source)
        importCover(source, onSuccess: onSuccess)
        return true
    }

    func handleDrop(
        providers: [NSItemProvider],
        language: AppLanguage,
        onWillStart: (() -> Void)? = nil,
        onSuccess: ((String) -> Void)? = nil
    ) -> Bool {
        let id = UUID()
        dropID = id
        let accepted = CoverManager.shared.readDroppedImage(from: providers) { [weak self] source in
            guard let self, self.dropID == id else { return }
            self.dropID = nil
            if let source {
                self.importCover(source, onSuccess: onSuccess)
            } else {
                self.isLoading = false
                self.errorMessage = CoverError.invalidImageData.message(in: language)
            }
        }
        if accepted {
            importTask?.cancel()
            importTask = nil
            errorMessage = nil
            onWillStart?()
            isLoading = true
        } else {
            dropID = nil
        }
        return accepted
    }

    func importCover(_ source: CoverSource, onSuccess: ((String) -> Void)? = nil) {
        cancelImport()
        errorMessage = nil
        isLoading = true
        let taskID = UUID()
        importTask = Task { [weak self] in
            do {
                let saved = try await CoverManager.shared.saveCover(from: source)
                guard !Task.isCancelled, let self else {
                    CoverManager.shared.removeCover(fileName: saved)
                    return
                }
                _ = taskID
                self.stageTemporaryCover(saved)
                self.isLoading = false
                onSuccess?(saved)
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.isLoading = false
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func importCandidate(
        fullURL: String,
        previewURL: String,
        failureMessage: String,
        onSuccess: @escaping (String) -> Void,
        onFailure: (() -> Void)? = nil
    ) {
        cancelImport()
        errorMessage = nil
        isLoading = true
        importTask = Task { [weak self] in
            do {
                let saved: String
                do {
                    saved = try await CoverManager.shared.saveCover(from: .remote(fullURL))
                } catch {
                    try Task.checkCancellation()
                    guard previewURL != fullURL else { throw error }
                    saved = try await CoverManager.shared.saveCover(from: .remote(previewURL))
                }
                guard !Task.isCancelled, let self else {
                    CoverManager.shared.removeCover(fileName: saved)
                    return
                }
                self.stageTemporaryCover(saved)
                self.isLoading = false
                onSuccess(saved)
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.isLoading = false
                self.errorMessage = failureMessage
                onFailure?()
            }
        }
    }

    /// Keeps the currently selected cover file and deletes all other temporary covers created during the session.
    func commitAndCleanupUnused() -> String? {
        let chosen = coverFileName
        for temp in temporaryFiles where temp != chosen && temp != preservedFileName {
            CoverManager.shared.removeCover(fileName: temp)
        }
        temporaryFiles.removeAll()
        return chosen
    }

    /// Cancels in-flight tasks and removes all uncommitted temporary covers.
    func tearDownAndCleanupUncommitted() {
        cancelImport()
        for temp in temporaryFiles where temp != preservedFileName {
            CoverManager.shared.removeCover(fileName: temp)
        }
        temporaryFiles.removeAll()
    }
}

/// Reusable poster preview box with drop-target dashed border and loading overlay.
struct CoverDropPreviewView: View {
    let coverFileName: String?
    let title: String
    let category: MediaCategory
    let subtag: String
    let paletteSeed: Int
    let language: AppLanguage
    let width: CGFloat
    let height: CGFloat
    let isDropTargeted: Bool
    let isLoading: Bool
    let dropPrompt: String
    var loadingPrompt: String? = nil

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black)
                .frame(width: width, height: height)
                .shadow(color: .black.opacity(0.28), radius: 12, x: 0, y: 6)

            CoverPreview(fileName: coverFileName) { artwork in
                CoverArtworkView(
                    title: title,
                    category: category,
                    subtag: subtag,
                    image: artwork?.image,
                    paletteSeed: paletteSeed,
                    language: language,
                    cornerRadius: 12,
                    isHovered: isDropTargeted
                )
            }
            .frame(width: width, height: height)

            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accentColor.opacity(0.32))
                    .frame(width: width, height: height)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    )
                    .overlay(
                        Text(dropPrompt)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.black.opacity(0.75), in: Capsule())
                    )
            }

            if isLoading {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.black.opacity(0.52))
                    .frame(width: width, height: height)
                    .overlay(
                        VStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.regular)
                                .tint(.white)
                            if let loadingPrompt {
                                Text(loadingPrompt)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.9))
                            }
                        }
                    )
            }
        }
    }
}
