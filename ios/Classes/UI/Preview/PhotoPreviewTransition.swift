import UIKit

// MARK: - 转场动画器

class PhotoPreviewAnimator: NSObject, UIViewControllerAnimatedTransitioning {

    let isPresenting: Bool
    let sourceFrame: CGRect

    init(isPresenting: Bool, sourceFrame: CGRect = .zero) {
        self.isPresenting = isPresenting
        self.sourceFrame = sourceFrame
        super.init()
    }

    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        return UIConstants.Animation.transitionDuration
    }

    func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        if isPresenting {
            animatePresentation(using: transitionContext)
        } else {
            animateDismissal(using: transitionContext)
        }
    }

    private func animatePresentation(using context: UIViewControllerContextTransitioning) {
        guard let toView = context.view(forKey: .to) else {
            context.completeTransition(true)
            return
        }

        let containerView = context.containerView
        containerView.addSubview(toView)

        toView.alpha = 0
        toView.transform = CGAffineTransform(scaleX: 0.95, y: 0.95)

        UIView.animate(
            withDuration: transitionDuration(using: context),
            delay: 0,
            options: .curveEaseOut,
            animations: {
                toView.alpha = 1
                toView.transform = .identity
            },
            completion: { _ in
                context.completeTransition(!context.transitionWasCancelled)
            }
        )
    }

    private func animateDismissal(using context: UIViewControllerContextTransitioning) {
        guard let fromVC = context.viewController(forKey: .from) as? PhotoPreviewPageViewController,
              let fromView = context.view(forKey: .from) else {
            context.completeTransition(true)
            return
        }

        let containerView = context.containerView
        let backgroundView = UIView(frame: containerView.bounds)
        backgroundView.backgroundColor = .black
        backgroundView.alpha = fromVC.dismissalBackgroundAlpha
        containerView.insertSubview(backgroundView, belowSubview: fromView)
        let duration = transitionDuration(using: context)

        if !sourceFrame.isEmpty {
            let snapshotView = createSnapshotView(from: fromVC, in: containerView)

            if let snapshot = snapshotView {
                containerView.addSubview(snapshot)
                fromView.alpha = 0

                UIView.animate(
                    withDuration: duration,
                    delay: 0,
                    options: .curveLinear,
                    animations: {
                        backgroundView.alpha = 0
                    }
                )

                UIView.animate(
                    withDuration: duration,
                    delay: 0,
                    options: [.curveEaseOut, .beginFromCurrentState],
                    animations: {
                        snapshot.frame = self.sourceFrame
                        snapshot.alpha = 0.92
                    },
                    completion: { _ in
                        backgroundView.removeFromSuperview()
                        snapshot.removeFromSuperview()
                        context.completeTransition(!context.transitionWasCancelled)
                    }
                )
            } else {
                fallbackDismissal(fromView: fromView, backgroundView: backgroundView, context: context)
            }
        } else {
            fallbackDismissal(fromView: fromView, backgroundView: backgroundView, context: context)
        }
    }

    private func createSnapshotView(from previewVC: PhotoPreviewPageViewController, in containerView: UIView) -> UIView? {
        guard let photoVC = previewVC.currentPhotoVC,
              let image = photoVC.imageView.image else {
            return nil
        }

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.frame = photoVC.imageView.convert(photoVC.imageView.bounds, to: containerView)

        return imageView
    }

    private func fallbackDismissal(
        fromView: UIView,
        backgroundView: UIView,
        context: UIViewControllerContextTransitioning
    ) {
        let duration = transitionDuration(using: context)
        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: .curveEaseIn,
            animations: {
                backgroundView.alpha = 0
                fromView.alpha = 0
                fromView.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
            },
            completion: { _ in
                backgroundView.removeFromSuperview()
                context.completeTransition(!context.transitionWasCancelled)
            }
        )
    }
}

// MARK: - Presentation Controller

class PhotoPreviewPresentationController: UIPresentationController {

    override var frameOfPresentedViewInContainerView: CGRect {
        return containerView?.bounds ?? .zero
    }

    override var shouldRemovePresentersView: Bool {
        return false  // 保留下层视图，这样下滑时可以看到
    }

    override func presentationTransitionWillBegin() {
        // 不添加 dimmingView，让 presentedViewController 自己控制背景
        guard let presentedView = presentedView else { return }
        presentedView.frame = frameOfPresentedViewInContainerView
    }

    override func dismissalTransitionWillBegin() {
        super.dismissalTransitionWillBegin()
        // Race condition: user dismisses preview while crop is still mid-dismiss.
        // UIKit has moved preview's view into the crop container; restore it to our
        // own containerView so the dismiss animation has the correct source view,
        // then remove the crop container so it doesn't orphan after our dismiss.
        guard let previewVC = presentedViewController as? PhotoPreviewPageViewController,
              let cropContainer = previewVC.cropPresentationContainer else { return }
        if let myContainer = containerView, previewVC.view.superview === cropContainer {
            previewVC.view.frame = myContainer.bounds
            myContainer.addSubview(previewVC.view)
        }
        cropContainer.removeFromSuperview()
        previewVC.cropPresentationContainer = nil
    }

    override func dismissalTransitionDidEnd(_ completed: Bool) {
        // Capture BEFORE calling super — UIKit clears these properties inside super,
        // so accessing them afterwards returns nil and removeFromSuperview() becomes a no-op.
        let capturedContainer = containerView
        let capturedPresented = presentedView
        super.dismissalTransitionDidEnd(completed)
        if completed {
            capturedPresented?.removeFromSuperview()
            capturedContainer?.removeFromSuperview()
        }
    }

    override func containerViewWillLayoutSubviews() {
        super.containerViewWillLayoutSubviews()
        presentedView?.frame = frameOfPresentedViewInContainerView
    }
}
