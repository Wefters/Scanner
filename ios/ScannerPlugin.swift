import AVFoundation
import CoreImage
import PhotosUI
import UIKit
import Vision

/// Barcode and QR scanning with AVFoundation in a full-screen `ScannerViewController`, plus decoding codes
/// from photos with Vision. Only one scanner is open at a time.
final class ScannerPlugin: WefterPlugin {

    private static let validFormats: Set<String> = ["qr", "ean13", "ean8", "code128", "code39", "upca", "upce"]

    private weak var activeController: ScannerViewController?
    private var presentedScanner: ScannerViewController?
    private var queuedScan: (id: String?, start: () -> Void)?

    /// Validates the options, asks for camera permission if needed and opens the scanner. Rejects with
    /// `INVALID_FORMAT` for unknown formats and `PERMISSION_DENIED` when camera access is refused.
    // @WefterMethod
    func scan(payload: [String: Any], callback: @escaping (Result<Any, Error>) -> Void) throws {
        let prompt = payload["prompt"] as? String ?? ""
        let continuous = payload["continuous"] as? Bool ?? false
        let allowGallery = payload["allowGallery"] as? Bool ?? true
        let id = payload["id"] as? String
        let requestedFormats = (payload["formats"] as? [String])?.filter { !$0.isEmpty } ?? ["qr"]
        let haptics = payload["haptics"] as? Bool ?? true
        let zoom = (payload["zoom"] as? NSNumber)?.doubleValue ?? 1.0
        let maxZoom = (payload["maxZoom"] as? NSNumber)?.doubleValue ?? 3.0
        let zoomControl = payload["zoomControl"] as? Bool ?? true
        let focusOnTap = payload["focusOnTap"] as? Bool ?? true
        let timeoutSeconds = (payload["timeout"] as? NSNumber)?.intValue ?? 0

        let unknown = requestedFormats.filter { $0 != "all" && !ScannerPlugin.validFormats.contains($0) }
        if !unknown.isEmpty {
            reject(
                callback,
                code: "INVALID_FORMAT",
                message: "Unknown barcode format(s): \(unknown.joined(separator: ", ")). Valid formats are: \(ScannerPlugin.validFormats.sorted().joined(separator: ", ")), all."
            )
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            DispatchQueue.main.async { [weak self] in
                self?.present(
                    prompt: prompt,
                    continuous: continuous,
                    allowGallery: allowGallery,
                    formats: requestedFormats,
                    haptics: haptics,
                    zoom: zoom,
                    maxZoom: maxZoom,
                    zoomControl: zoomControl,
                    focusOnTap: focusOnTap,
                    timeoutSeconds: timeoutSeconds,
                    id: id
                )
            }
            resolve(callback, data: ["started": true])

        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if granted {
                        self.present(
                            prompt: prompt,
                            continuous: continuous,
                            allowGallery: allowGallery,
                            formats: requestedFormats,
                            haptics: haptics,
                            zoom: zoom,
                            maxZoom: maxZoom,
                            zoomControl: zoomControl,
                            focusOnTap: focusOnTap,
                            timeoutSeconds: timeoutSeconds,
                            id: id
                        )
                        self.resolve(callback, data: ["started": true])
                    } else {
                        self.reject(callback, code: "PERMISSION_DENIED", message: "Camera permission was denied")
                    }
                }
            }

        case .denied, .restricted:
            reject(callback, code: "PERMISSION_DENIED", message: "Camera access is denied. Enable it in Settings to use the scanner.")

        @unknown default:
            reject(callback, code: "PERMISSION_DENIED", message: "Camera access is unavailable.")
        }
    }

    /// Closes the scanner with the given `id`, or whichever is open without one.
    // @WefterMethod
    func stop(payload: [String: Any], callback: @escaping (Result<Any, Error>) -> Void) throws {
        let id = payload["id"] as? String

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let queued = self.queuedScan, id == nil || queued.id == id {
                self.queuedScan = nil
                self.dispatchCancelled(reason: "stopped_by_app", id: queued.id)
                self.resolve(callback, data: ["stopped": true])
                return
            }
            guard let controller = self.activeController, id == nil || controller.sessionId == id else {
                self.resolve(callback, data: ["stopped": false])
                return
            }
            controller.finish(cancelled: true, reason: "stopped_by_app")
            self.resolve(callback, data: ["stopped": true])
        }
    }

    /// Presents the scanner full screen and wires its results to events.
    private func present(prompt: String, continuous: Bool, allowGallery: Bool, formats: [String], haptics: Bool, zoom: Double, maxZoom: Double, zoomControl: Bool, focusOnTap: Bool, timeoutSeconds: Int, id: String?) {
        if let previous = presentedScanner {
            queuedScan = (id: id, start: { [weak self] in
                self?.present(prompt: prompt, continuous: continuous, allowGallery: allowGallery, formats: formats, haptics: haptics, zoom: zoom, maxZoom: maxZoom, zoomControl: zoomControl, focusOnTap: focusOnTap, timeoutSeconds: timeoutSeconds, id: id)
            })
            if activeController === previous { activeController = nil }
            previous.finish(cancelled: true, reason: nil)
            return
        }

        let rootViewController = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: { $0.isKeyWindow })?.rootViewController

        guard var presenter = rootViewController else {
            dispatchCancelled(reason: "no_root_view_controller", id: id)
            return
        }
        while let presented = presenter.presentedViewController, !presented.isBeingDismissed {
            presenter = presented
        }

        let types = ScannerPlugin.metadataObjectTypes(for: formats)
        let controller = ScannerViewController(
            prompt: prompt,
            continuous: continuous,
            allowGallery: allowGallery,
            formats: formats,
            types: types,
            haptics: haptics,
            zoom: zoom,
            maxZoom: maxZoom,
            zoomControl: zoomControl,
            focusOnTap: focusOnTap,
            timeoutSeconds: timeoutSeconds,
            id: id
        )
        controller.onCodeScanned = { [weak self] data, format in
            self?.dispatchCodeScanned(data: data, format: format, id: id)
        }
        controller.onCancelled = { [weak self, weak controller] reason in
            guard let self = self else { return }
            if self.activeController === controller {
                self.activeController = nil
            }
            self.dispatchCancelled(reason: reason, id: id)
        }
        controller.onDismissed = { [weak self, weak controller] in
            guard let self = self, self.presentedScanner === controller else { return }
            self.presentedScanner = nil
            if let next = self.queuedScan {
                self.queuedScan = nil
                next.start()
            }
        }
        controller.modalPresentationStyle = .fullScreen
        activeController = controller
        presentedScanner = controller
        presenter.present(controller, animated: true)

        if controller.presentingViewController == nil {
            activeController = nil
            presentedScanner = nil
            dispatchCancelled(reason: "presentation_failed", id: id)
        }
    }

    /// Emits `scanner:codeScanned`.
    private func dispatchCodeScanned(data: String, format: String, id: String?) {
        var payload: [String: Any] = ["data": data, "format": format]
        if let id = id { payload["id"] = id }
        emit("scanner:codeScanned", payload)
    }

    /// Emits `scanner:cancelled`.
    private func dispatchCancelled(reason: String, id: String?) {
        var payload: [String: Any] = ["reason": reason]
        if let id = id { payload["id"] = id }
        emit("scanner:cancelled", payload)
    }

    /// AVFoundation metadata types for the requested format names.
    private static func metadataObjectTypes(for names: [String]) -> [AVMetadataObject.ObjectType] {
        if names.contains("all") {
            return [.qr, .ean13, .ean8, .code128, .code39, .upce, .code93, .pdf417, .aztec, .dataMatrix, .interleaved2of5, .itf14, .codabar]
        }

        var types = Set<AVMetadataObject.ObjectType>()
        for name in names {
            switch name {
            case "qr": types.insert(.qr)
            case "ean13": types.insert(.ean13)
            case "ean8": types.insert(.ean8)
            case "code128": types.insert(.code128)
            case "code39": types.insert(.code39)
            case "upce": types.insert(.upce)
            case "upca": types.insert(.ean13)
            default: break
            }
        }
        return Array(types)
    }

    /// Vision symbologies for the requested format names, used to decode photos.
    static func barcodeSymbologies(for names: [String]) -> [VNBarcodeSymbology] {
        if names.contains("all") {
            return [.qr, .ean13, .ean8, .code128, .code39, .upce, .code93, .pdf417, .aztec, .dataMatrix, .itf14, .codabar]
        }

        var symbologies = Set<VNBarcodeSymbology>()
        for name in names {
            switch name {
            case "qr": symbologies.insert(.qr)
            case "ean13": symbologies.insert(.ean13)
            case "ean8": symbologies.insert(.ean8)
            case "code128": symbologies.insert(.code128)
            case "code39": symbologies.insert(.code39)
            case "upce": symbologies.insert(.upce)
            case "upca": symbologies.insert(.ean13)
            default: break
            }
        }
        return symbologies.isEmpty ? [.qr] : Array(symbologies)
    }
}

/// Dims the camera preview outside the scan area and draws its corner brackets.
final class ViewfinderOverlayView: UIView {

    private static let successColor = UIColor(red: 0.20, green: 0.83, blue: 0.60, alpha: 1)
    private static let cornerRadius: CGFloat = 24

    private let borderLayer = CAShapeLayer()
    private let pulseLayer = CAShapeLayer()

    private(set) var scanWindowFrame: CGRect = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false

        borderLayer.fillColor = UIColor.clear.cgColor
        borderLayer.strokeColor = UIColor.white.cgColor
        borderLayer.lineWidth = 3
        layer.addSublayer(borderLayer)

        pulseLayer.fillColor = UIColor.clear.cgColor
        pulseLayer.strokeColor = ViewfinderOverlayView.successColor.cgColor
        pulseLayer.lineWidth = 4
        pulseLayer.opacity = 0
        layer.addSublayer(pulseLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let side = min(bounds.width, bounds.height) * 0.68
        let rect = CGRect(
            x: (bounds.width - side) / 2,
            y: bounds.height * 0.26,
            width: side,
            height: side
        )
        scanWindowFrame = rect
        borderLayer.path = UIBezierPath(roundedRect: rect, cornerRadius: ViewfinderOverlayView.cornerRadius).cgPath
    }

    /// Flashes the brackets green, moving them onto the found code when its position is known.
    func playSuccessPulse(duration: TimeInterval, targetRect: CGRect?) {
        let target = targetRect ?? scanWindowFrame
        guard target.width > 0, target.height > 0 else { return }

        borderLayer.opacity = 0

        let radius = min(target.width, target.height) * 0.12
        let inflated = target.insetBy(dx: -target.width * 0.15, dy: -target.height * 0.15)
        let startPath = UIBezierPath(roundedRect: inflated, cornerRadius: radius * 1.3).cgPath
        let exactPath = UIBezierPath(roundedRect: target, cornerRadius: radius).cgPath

        pulseLayer.removeAllAnimations()
        pulseLayer.path = exactPath
        pulseLayer.opacity = 0

        let pathAnimation = CAKeyframeAnimation(keyPath: "path")
        pathAnimation.values = [startPath, exactPath, exactPath, exactPath]
        pathAnimation.keyTimes = [0, 0.25, 0.7, 1.0]
        pathAnimation.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .linear),
            CAMediaTimingFunction(name: .linear),
        ]

        let fadeAnimation = CAKeyframeAnimation(keyPath: "opacity")
        fadeAnimation.values = [1.0, 1.0, 1.0, 0.0]
        fadeAnimation.keyTimes = [0, 0.25, 0.7, 1.0]

        let group = CAAnimationGroup()
        group.animations = [pathAnimation, fadeAnimation]
        group.duration = duration

        pulseLayer.add(group, forKey: "successPulse")

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            self?.borderLayer.opacity = 1
        }
    }
}

/// The square shown where the user tapped to focus.
final class FocusIndicatorView: UIView {

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Shows the indicator at `point` and fades it out.
    func animateFocus(at point: CGPoint) {
        let size: CGFloat = 72
        let ring = UIView(frame: CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size))
        ring.layer.borderColor = UIColor.white.cgColor
        ring.layer.borderWidth = 1.5
        ring.layer.cornerRadius = size / 2
        ring.alpha = 0
        ring.transform = CGAffineTransform(scaleX: 1.3, y: 1.3)
        addSubview(ring)

        UIView.animate(withDuration: 0.18, animations: {
            ring.alpha = 1
            ring.transform = .identity
        }) { _ in
            UIView.animate(withDuration: 0.3, delay: 0.4, options: [], animations: {
                ring.alpha = 0
            }) { _ in
                ring.removeFromSuperview()
            }
        }
    }
}

/// A horizontal slider for the camera zoom, drawn by hand.
final class CameraZoomSliderView: UIView {

    var minValue: CGFloat = 1.0
    var maxValue: CGFloat = 3.0
    var onValueChanged: ((CGFloat) -> Void)?

    var value: CGFloat = 1.0 {
        didSet {
            let clamped = min(max(value, minValue), maxValue)
            if clamped != value {
                value = clamped
                return
            }
            setNeedsDisplay()
        }
    }

    private let thumbRadius: CGFloat = 9
    private let trackColor = UIColor.white.withAlphaComponent(0.3)
    private let progressColor = UIColor.white
    private let thumbColor = UIColor.white
    private let thumbShadowColor = UIColor.black.withAlphaComponent(0.25)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var trackLeft: CGFloat { thumbRadius }
    private var trackRight: CGFloat { bounds.width - thumbRadius }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let cy = bounds.height / 2
        let left = trackLeft
        let right = trackRight
        guard right > left else { return }

        let range = max(maxValue - minValue, 0.001)
        let ratio = (value - minValue) / range
        let thumbX = left + (right - left) * ratio

        ctx.setLineCap(.round)
        ctx.setLineWidth(2)

        ctx.setStrokeColor(trackColor.cgColor)
        ctx.move(to: CGPoint(x: left, y: cy))
        ctx.addLine(to: CGPoint(x: right, y: cy))
        ctx.strokePath()

        ctx.setStrokeColor(progressColor.cgColor)
        ctx.move(to: CGPoint(x: left, y: cy))
        ctx.addLine(to: CGPoint(x: thumbX, y: cy))
        ctx.strokePath()

        ctx.setFillColor(thumbShadowColor.cgColor)
        ctx.fillEllipse(in: CGRect(x: thumbX - thumbRadius, y: cy - thumbRadius + 1, width: thumbRadius * 2, height: thumbRadius * 2))

        ctx.setFillColor(thumbColor.cgColor)
        ctx.fillEllipse(in: CGRect(x: thumbX - thumbRadius, y: cy - thumbRadius, width: thumbRadius * 2, height: thumbRadius * 2))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        updateValue(fromTouchX: touch.location(in: self).x)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        updateValue(fromTouchX: touch.location(in: self).x)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        updateValue(fromTouchX: touch.location(in: self).x)
    }

    /// Sets the value from a touch position and reports it.
    private func updateValue(fromTouchX x: CGFloat) {
        let left = trackLeft
        let right = trackRight
        guard right > left else { return }
        let ratio = min(max((x - left) / (right - left), 0), 1)
        let newValue = minValue + (maxValue - minValue) * ratio
        value = newValue
        onValueChanged?(newValue)
    }
}

/// The scanner screen: camera preview, viewfinder, prompt, close, torch and gallery buttons, an optional zoom
/// slider and tap to focus. In continuous mode repeated reads of the same code are ignored for a moment.
final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {

    private let prompt: String
    private let continuous: Bool
    private let allowGallery: Bool
    private let requestedFormats: [String]
    private let types: [AVMetadataObject.ObjectType]
    private let hapticsEnabled: Bool
    private let initialZoom: Double
    private let maxZoomConfigured: Double
    private let zoomControlEnabled: Bool
    private let focusOnTap: Bool
    private let timeoutSeconds: Int
    let sessionId: String?

    var onCodeScanned: ((String, String) -> Void)?
    var onCancelled: ((String) -> Void)?
    var onDismissed: (() -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "dev.wefter.scanner.session")
    private var sessionTornDown = false
    private var pendingDismiss = false
    private var dismissInFlight = false
    private var hasAppeared = false
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var captureDevice: AVCaptureDevice?
    private var finished = false
    private var matched = false
    private var torchOn = false
    private let torchButton = UIButton(type: .system)
    private let galleryButton = UIButton(type: .system)
    private var promptLabel: UILabel?
    private let viewfinderOverlay = ViewfinderOverlayView()
    private let focusIndicatorView = FocusIndicatorView()
    private let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
    private var timeoutWorkItem: DispatchWorkItem?
    private var cameraAvailable = true
    private let cameraUnavailableView = UIStackView()

    private let zoomSliderView = CameraZoomSliderView()
    private let zoomValueLabel = UILabel()
    private var zoomLowerBound: CGFloat = 1.0
    private var zoomUpperBound: CGFloat = 3.0
    private var currentZoom: CGFloat = 1.0

    private var lastValue: String?
    private var lastFiredAt: TimeInterval = 0
    private let repeatDebounceSeconds: TimeInterval = 2.0
    private static let successPulseDuration: TimeInterval = 1.0

    /// Creates the scanner with its options. `timeoutSeconds` of 0 never times out.
    init(prompt: String, continuous: Bool, allowGallery: Bool, formats: [String], types: [AVMetadataObject.ObjectType], haptics: Bool, zoom: Double, maxZoom: Double, zoomControl: Bool, focusOnTap: Bool, timeoutSeconds: Int, id: String?) {
        self.prompt = prompt
        self.continuous = continuous
        self.allowGallery = allowGallery
        self.requestedFormats = formats
        self.types = types
        self.hapticsEnabled = haptics
        self.initialZoom = zoom
        self.maxZoomConfigured = maxZoom
        self.zoomControlEnabled = zoomControl
        self.focusOnTap = focusOnTap
        self.timeoutSeconds = timeoutSeconds
        self.sessionId = id
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Sets up the camera, the overlay and the timeout, switching to the "camera unavailable" view on devices
    /// without a usable camera.
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setUpCamera()
        setUpOverlay()
        setUpCameraUnavailableView()
        if !cameraAvailable { applyCameraUnavailableUI() }

        if hapticsEnabled {
            impactFeedback.prepare()
        }

        if timeoutSeconds > 0 {
            let workItem = DispatchWorkItem { [weak self] in
                self?.finish(cancelled: true, reason: "timeout")
            }
            timeoutWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(timeoutSeconds), execute: workItem)
        }
    }

    deinit {
        let session = self.session
        sessionQueue.async {
            if session.isRunning { session.stopRunning() }
        }
    }

    /// Starts the capture session.
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard !finished else { return }
        startSession()
    }

    /// Carries out a dismissal that was requested before the screen finished appearing.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        hasAppeared = true
        if pendingDismiss {
            pendingDismiss = false
            performDismiss()
        }
    }

    /// Pauses the capture session.
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if finished {
            tearDownSession()
        } else {
            pauseSession()
        }
    }

    /// Starts capturing on a background queue.
    private func startSession() {
        guard cameraAvailable else { return }
        sessionQueue.async { [session, weak self] in
            guard let self = self, !self.sessionTornDown, !session.isRunning else { return }
            session.startRunning()
        }
    }

    /// Stops capturing without releasing the camera.
    private func pauseSession() {
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    /// Stops capturing and releases the camera.
    private func tearDownSession() {
        let device = captureDevice
        sessionQueue.async { [session, weak self] in
            self?.sessionTornDown = true
            if let device = device, device.hasTorch, device.torchMode != .off,
               (try? device.lockForConfiguration()) != nil {
                device.torchMode = .off
                device.unlockForConfiguration()
            }
            if session.isRunning { session.stopRunning() }
            session.beginConfiguration()
            session.inputs.forEach { session.removeInput($0) }
            session.outputs.forEach { session.removeOutput($0) }
            session.commitConfiguration()
        }
    }

    /// Lays out the preview and limits detection to the area inside the viewfinder.
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds

        viewfinderOverlay.frame = view.bounds
        viewfinderOverlay.layoutIfNeeded()

        let square = viewfinderOverlay.scanWindowFrame
        if !cameraUnavailableView.isHidden {
            let width = max(square.width - 40, 0)
            let height = min(
                cameraUnavailableView.systemLayoutSizeFitting(
                    CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                    withHorizontalFittingPriority: .required,
                    verticalFittingPriority: .fittingSizeLevel
                ).height,
                square.height - 40
            )
            cameraUnavailableView.frame = CGRect(x: square.midX - width / 2, y: square.midY - height / 2, width: width, height: height)
        }

        if allowGallery {
            var size = galleryButton.bounds.size
            if size == .zero {
                galleryButton.sizeToFit()
                size = galleryButton.bounds.size
            }
            galleryButton.frame = CGRect(
                x: (view.bounds.width - size.width) / 2,
                y: square.maxY + 28,
                width: size.width,
                height: size.height
            )
        }

        if zoomControlEnabled {
            let sliderWidth: CGFloat = 200
            let sliderHeight: CGFloat = 32
            let labelHeight: CGFloat = 18
            let labelGap: CGFloat = 4

            let bottomLimit: CGFloat
            if let promptLabel = promptLabel, !prompt.isEmpty {
                bottomLimit = promptLabel.frame.minY - 14
            } else {
                bottomLimit = view.bounds.height - view.safeAreaInsets.bottom - 28
            }

            zoomSliderView.frame = CGRect(
                x: (view.bounds.width - sliderWidth) / 2,
                y: bottomLimit - sliderHeight,
                width: sliderWidth,
                height: sliderHeight
            )
            zoomValueLabel.frame = CGRect(
                x: (view.bounds.width - sliderWidth) / 2,
                y: zoomSliderView.frame.minY - labelGap - labelHeight,
                width: sliderWidth,
                height: labelHeight
            )
        }
    }

    /// Switches to the "camera unavailable" view.
    private func handleCameraUnavailable() {
        guard !finished, cameraAvailable else { return }
        cameraAvailable = false
        guard allowGallery else {
            finish(cancelled: true, reason: "camera_error")
            return
        }
        tearDownSession()
        if isViewLoaded { applyCameraUnavailableUI() }
    }

    /// Builds the view shown when the camera cannot be used.
    private func setUpCameraUnavailableView() {
        let icon = UIImageView(image: UIImage(systemName: "video.slash.fill"))
        icon.tintColor = UIColor.white.withAlphaComponent(0.85)
        icon.contentMode = .scaleAspectFit
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 34, weight: .regular)

        let title = UILabel()
        title.text = "Camera unavailable"
        title.textColor = .white
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textAlignment = .center

        let message = UILabel()
        message.text = "You can still scan a code from a photo in your gallery."
        message.textColor = UIColor.white.withAlphaComponent(0.7)
        message.font = .systemFont(ofSize: 14)
        message.textAlignment = .center
        message.numberOfLines = 0

        [icon, title, message].forEach { cameraUnavailableView.addArrangedSubview($0) }
        cameraUnavailableView.axis = .vertical
        cameraUnavailableView.alignment = .center
        cameraUnavailableView.distribution = .fill
        cameraUnavailableView.spacing = 10
        cameraUnavailableView.setCustomSpacing(6, after: title)
        cameraUnavailableView.isUserInteractionEnabled = false
        cameraUnavailableView.isHidden = true
        cameraUnavailableView.accessibilityElements = [title, message]
        view.addSubview(cameraUnavailableView)
    }

    /// Hides the camera controls and shows the unavailable view.
    private func applyCameraUnavailableUI() {
        previewLayer?.isHidden = true
        torchButton.isHidden = true
        zoomSliderView.isHidden = true
        zoomValueLabel.isHidden = true
        promptLabel?.isHidden = true
        view.gestureRecognizers?.forEach { $0.isEnabled = false }
        cameraUnavailableView.isHidden = false
        view.bringSubviewToFront(cameraUnavailableView)
        view.setNeedsLayout()
        UIAccessibility.post(notification: .layoutChanged, argument: cameraUnavailableView)
    }

    /// The capture session failed (for example the camera was taken by another app).
    @objc private func sessionRuntimeError(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.handleCameraUnavailable()
        }
    }

    /// Configures the camera input, the metadata output for the requested formats and the starting zoom.
    private func setUpCamera() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            handleCameraUnavailable()
            return
        }
        session.addInput(input)
        captureDevice = device

        if zoomControlEnabled || initialZoom != 1.0 {
            let deviceMin = max(device.minAvailableVideoZoomFactor, 1.0)
            let deviceMax = device.maxAvailableVideoZoomFactor
            zoomLowerBound = deviceMin
            zoomUpperBound = max(min(CGFloat(maxZoomConfigured), deviceMax), deviceMin)

            let clampedZoom = min(max(CGFloat(initialZoom), zoomLowerBound), zoomUpperBound)
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = clampedZoom
                device.unlockForConfiguration()
            } catch {
            }
            currentZoom = clampedZoom
        }

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            handleCameraUnavailable()
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = types.filter { output.availableMetadataObjectTypes.contains($0) }

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.insertSublayer(layer, at: 0)
        previewLayer = layer

        NotificationCenter.default.addObserver(
            self, selector: #selector(sessionRuntimeError(_:)),
            name: AVCaptureSession.runtimeErrorNotification, object: session
        )
    }

    /// Builds the viewfinder, prompt, buttons, zoom slider and focus gesture.
    private func setUpOverlay() {
        viewfinderOverlay.frame = view.bounds
        viewfinderOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        viewfinderOverlay.isUserInteractionEnabled = false
        view.addSubview(viewfinderOverlay)

        focusIndicatorView.frame = view.bounds
        focusIndicatorView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        focusIndicatorView.isUserInteractionEnabled = false
        view.addSubview(focusIndicatorView)

        if focusOnTap {
            let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleFocusTap(_:)))
            tapGesture.delegate = self
            view.addGestureRecognizer(tapGesture)
        }

        let titleLabel = UILabel()
        titleLabel.text = "Scan Code"
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleLabel)

        let closeButton = UIButton(type: .system)
        closeButton.setImage(UIImage(systemName: "xmark")?.withRenderingMode(.alwaysTemplate), for: .normal)
        styleIconButton(closeButton)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        view.addSubview(closeButton)

        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            closeButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            closeButton.widthAnchor.constraint(equalToConstant: 40),
            closeButton.heightAnchor.constraint(equalToConstant: 40),

            titleLabel.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])

        if allowGallery {
            galleryButton.setTitle("Choose from Gallery", for: .normal)
            galleryButton.setTitleColor(.white, for: .normal)
            galleryButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
            galleryButton.backgroundColor = UIColor.white.withAlphaComponent(0.14)
            galleryButton.layer.borderWidth = 1.5
            galleryButton.layer.borderColor = UIColor.white.cgColor
            galleryButton.layer.cornerRadius = 22
            galleryButton.contentEdgeInsets = UIEdgeInsets(top: 12, left: 24, bottom: 12, right: 24)
            galleryButton.addTarget(self, action: #selector(galleryTapped), for: .touchUpInside)
            view.addSubview(galleryButton)
            galleryButton.sizeToFit()
        }

        if zoomControlEnabled {
            zoomValueLabel.text = String(format: "%.1fx", currentZoom)
            zoomValueLabel.textColor = .white
            zoomValueLabel.font = .systemFont(ofSize: 13, weight: .semibold)
            zoomValueLabel.textAlignment = .center
            view.addSubview(zoomValueLabel)

            zoomSliderView.minValue = zoomLowerBound
            zoomSliderView.maxValue = zoomUpperBound
            zoomSliderView.value = currentZoom
            zoomSliderView.onValueChanged = { [weak self] newValue in
                self?.applyZoomFromSlider(newValue)
            }
            view.addSubview(zoomSliderView)
        }

        if !prompt.isEmpty {
            let promptLabel = UILabel()
            promptLabel.text = prompt
            promptLabel.textColor = .white
            promptLabel.textAlignment = .center
            promptLabel.numberOfLines = 0
            promptLabel.font = .systemFont(ofSize: 14, weight: .regular)
            promptLabel.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(promptLabel)
            self.promptLabel = promptLabel

            NSLayoutConstraint.activate([
                promptLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 32),
                promptLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -32),
                promptLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -32),
            ])
        }

        guard let device = captureDevice, device.hasTorch else { return }

        torchButton.setImage(UIImage(systemName: "bolt.slash.fill")?.withRenderingMode(.alwaysTemplate), for: .normal)
        styleIconButton(torchButton)
        torchButton.addTarget(self, action: #selector(torchTapped), for: .touchUpInside)
        view.addSubview(torchButton)

        NSLayoutConstraint.activate([
            torchButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            torchButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            torchButton.widthAnchor.constraint(equalToConstant: 40),
            torchButton.heightAnchor.constraint(equalToConstant: 40),
        ])
    }

    /// Applies the round overlay button style.
    private func styleIconButton(_ button: UIButton) {
        button.backgroundColor = .white
        button.tintColor = .black
        button.translatesAutoresizingMaskIntoConstraints = false
        button.layer.cornerRadius = 20
        button.clipsToBounds = true
        button.setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold),
            forImageIn: .normal
        )
    }

    /// Closes the scanner as cancelled by the user.
    @objc private func closeTapped() {
        guard finished else {
            finish(cancelled: true, reason: "user_cancelled")
            return
        }
        if !dismissInFlight, !isBeingDismissed {
            performDismiss()
        }
    }

    /// Opens the photo picker to scan a code from an image.
    @objc private func galleryTapped() {
        guard allowGallery else { return }

        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1

        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        present(picker, animated: true)
    }

    /// Focuses and meters at the tapped point.
    @objc private func handleFocusTap(_ gesture: UITapGestureRecognizer) {
        guard let device = captureDevice, let layer = previewLayer else { return }

        let location = gesture.location(in: view)
        let devicePoint = layer.captureDevicePointConverted(fromLayerPoint: location)

        do {
            try device.lockForConfiguration()
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = devicePoint
                device.focusMode = .autoFocus
            }
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = devicePoint
                device.exposureMode = .autoExpose
            }
            device.unlockForConfiguration()
            focusIndicatorView.animateFocus(at: location)
        } catch {
        }
    }

    /// Applies a zoom factor from the slider, within the device's limits and `maxZoom`.
    private func applyZoomFromSlider(_ value: CGFloat) {
        guard let device = captureDevice else { return }

        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = value
            device.unlockForConfiguration()
            currentZoom = value
            zoomValueLabel.text = String(format: "%.1fx", value)
        } catch {
        }
    }

    /// Turns the torch on or off.
    @objc private func torchTapped() {
        guard let device = captureDevice, device.hasTorch else { return }

        do {
            try device.lockForConfiguration()
            torchOn.toggle()
            device.torchMode = torchOn ? .on : .off
            device.unlockForConfiguration()
            let symbolName = torchOn ? "bolt.fill" : "bolt.slash.fill"
            torchButton.setImage(UIImage(systemName: symbolName)?.withRenderingMode(.alwaysTemplate), for: .normal)
        } catch {
        }
    }

    /// Handles detected codes: finishes with the first one, or in continuous mode reports each new one.
    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = object.stringValue else {
            return
        }

        let format = ScannerViewController.formatName(for: object.type, value: value, requested: requestedFormats)

        let codeRect = previewLayer?.transformedMetadataObject(for: object)?.bounds

        if !continuous {
            guard !matched else { return }
            matched = true

            triggerHapticFeedback()
            viewfinderOverlay.playSuccessPulse(duration: ScannerViewController.successPulseDuration, targetRect: codeRect)
            DispatchQueue.main.asyncAfter(deadline: .now() + ScannerViewController.successPulseDuration) { [weak self] in
                self?.finish(cancelled: false, data: value, format: format)
            }
            return
        }

        let now = Date().timeIntervalSince1970
        if value == lastValue, now - lastFiredAt < repeatDebounceSeconds {
            return
        }

        triggerHapticFeedback()
        viewfinderOverlay.playSuccessPulse(duration: ScannerViewController.successPulseDuration, targetRect: codeRect)
        lastValue = value
        lastFiredAt = now

        onCodeScanned?(value, format)
    }

    /// Vibrates briefly when haptics are enabled.
    private func triggerHapticFeedback() {
        guard hapticsEnabled else { return }
        impactFeedback.impactOccurred()
    }

    /// JavaScript name of a detected format. EAN-13 codes that are really UPC-A are reported as `upca` when
    /// that
    /// was requested.
    private static func formatName(for type: AVMetadataObject.ObjectType, value: String, requested: [String]) -> String {
        if type == .ean13, value.count == 13, value.hasPrefix("0"),
           requested.contains("upca") || requested.contains("all"), !requested.contains("ean13") {
            return "upca"
        }

        switch type {
        case .qr: return "qr"
        case .ean13: return "ean13"
        case .ean8: return "ean8"
        case .code128: return "code128"
        case .code39: return "code39"
        case .upce: return "upce"
        case .code93: return "code93"
        case .pdf417: return "pdf417"
        case .aztec: return "aztec"
        case .dataMatrix: return "data_matrix"
        case .interleaved2of5: return "itf"
        case .itf14: return "itf14"
        case .codabar: return "codabar"
        default: return "unknown"
        }
    }

    /// JavaScript name of a format decoded from a photo, with the same UPC-A handling.
    private static func formatName(forSymbology symbology: VNBarcodeSymbology, value: String, requested: [String]) -> String {
        if symbology == .ean13, value.count == 13, value.hasPrefix("0"),
           requested.contains("upca") || requested.contains("all"), !requested.contains("ean13") {
            return "upca"
        }

        switch symbology {
        case .qr: return "qr"
        case .ean13: return "ean13"
        case .ean8: return "ean8"
        case .code128: return "code128"
        case .code39: return "code39"
        case .upce: return "upce"
        case .code93: return "code93"
        case .pdf417: return "pdf417"
        case .aztec: return "aztec"
        case .dataMatrix: return "data_matrix"
        case .itf14: return "itf14"
        case .codabar: return "codabar"
        default: return "unknown"
        }
    }

    /// Loads the picked photo and decodes it.
    fileprivate func loadAndDecode(provider: NSItemProvider) {
        provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
            guard let self = self else { return }
            guard let image = object as? UIImage, let cgImage = image.cgImage else {
                DispatchQueue.main.async {
                    self.showGalleryAlert(message: "Couldn't read that image.")
                }
                return
            }
            self.decodeGalleryImage(cgImage)
        }
    }

    /// Looks for a code of the requested formats in an image with Vision, and for a QR code with Core Image
    /// when Vision finds none. Vision's barcode model can't run in the Simulator, so there only QR codes are read.
    private func decodeGalleryImage(_ cgImage: CGImage) {
        let symbologies = ScannerPlugin.barcodeSymbologies(for: requestedFormats)
        let request = VNDetectBarcodesRequest()
        request.symbologies = symbologies

        var visionFailed = false
        var match: (value: String, symbology: VNBarcodeSymbology)?
        do {
            try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
            if let observation = request.results?.first(where: { $0.payloadStringValue != nil }),
               let value = observation.payloadStringValue {
                match = (value, observation.symbology)
            }
        } catch {
            visionFailed = true
        }

        if match == nil, symbologies.contains(.qr), let value = ScannerViewController.decodeQRCode(in: cgImage) {
            match = (value, .qr)
        }

        guard let (value, symbology) = match else {
            DispatchQueue.main.async { [weak self] in
                self?.showGalleryAlert(message: visionFailed ? "Couldn't read that image." : "No code found in that image.")
            }
            return
        }

        let format = ScannerViewController.formatName(forSymbology: symbology, value: value, requested: requestedFormats)

        DispatchQueue.main.async { [weak self] in
            self?.triggerHapticFeedback()
            self?.finish(cancelled: false, data: value, format: format)
        }
    }

    /// The text of the first QR code Core Image finds in the image.
    private static func decodeQRCode(in cgImage: CGImage) -> String? {
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        let features = detector?.features(in: CIImage(cgImage: cgImage)) ?? []
        return features.lazy.compactMap { ($0 as? CIQRCodeFeature)?.messageString }.first
    }

    /// Tells the user that no code was found in the photo.
    private func showGalleryAlert(message: String) {
        guard !finished else { return }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    /// Ends the scan once: reports the code, or the cancellation reason, and dismisses the scanner.
    func finish(cancelled: Bool, data: String? = nil, format: String? = nil, reason: String? = nil) {
        guard !finished else { return }
        finished = true

        timeoutWorkItem?.cancel()
        tearDownSession()

        if hasAppeared {
            performDismiss()
        } else {
            pendingDismiss = true
        }

        if cancelled {
            guard let reason = reason else { return }
            onCancelled?(reason)
        } else if let data = data {
            onCodeScanned?(data, format ?? "unknown")
        }
    }
}

extension ScannerViewController {
    /// Dismisses the scanner and releases the camera.
    fileprivate func performDismiss() {
        guard let presenter = presentingViewController else {
            dismissFinished()
            return
        }
        dismissInFlight = true
        presenter.dismiss(animated: true) { [weak self] in
            self?.dismissInFlight = false
            self?.dismissFinished()
        }
    }

    /// Cleans up after the dismissal animation.
    private func dismissFinished() {
        let callback = onDismissed
        onDismissed = nil
        callback?()
    }
}

extension ScannerViewController: UIGestureRecognizerDelegate {
    /// Ignores focus taps on the overlay's buttons and slider.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        !(touch.view is UIControl)
    }
}

extension ScannerViewController: PHPickerViewControllerDelegate {
    /// Handles the photo picked from the gallery.
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else {
            picker.dismiss(animated: true)
            return
        }

        picker.dismiss(animated: true) { [weak self] in
            self?.loadAndDecode(provider: provider)
        }
    }
}
