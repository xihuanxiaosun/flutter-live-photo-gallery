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
        guard let toView = context.view(forKey: .to) else { return }

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
            return
        }

        let containerView = context.containerView

        // 如果有源位置，执行英雄式动画
        if !sourceFrame.isEmpty {
            // 获取当前显示的图片视图
            let snapshotView = createSnapshotView(from: fromVC)

            if let snapshot = snapshotView {
                // 保留当前的 transform 应用到 snapshot 的初始位置
                let currentTransform = fromVC.pageViewController.view.transform
                snapshot.transform = currentTransform

                containerView.addSubview(snapshot)

                // 隐藏原视图
                fromView.alpha = 0

                // 计算动画参数
                let finalFrame = sourceFrame

                UIView.animate(
                    withDuration: transitionDuration(using: context),
                    delay: 0,
                    options: .curveEaseInOut,
                    animations: {
                        // 重置 transform 并移动到目标位置
                        snapshot.transform = .identity
                        snapshot.frame = finalFrame
                        snapshot.alpha = 0.8
                    },
                    completion: { _ in
                        snapshot.removeFromSuperview()
                        context.completeTransition(!context.transitionWasCancelled)
                    }
                )
            } else {
                // 降级方案：简单淡出
                fallbackDismissal(fromView: fromView, context: context)
            }
        } else {
            // 降级方案：简单淡出
            fallbackDismissal(fromView: fromView, context: context)
        }
    }

    private func createSnapshotView(from previewVC: PhotoPreviewPageViewController) -> UIView? {
        guard let photoVC = previewVC.currentPhotoVC,
              let image = photoVC.imageView.image,
              let window = photoVC.view.window else {
            return nil
        }

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.frame = photoVC.imageView.convert(photoVC.imageView.bounds, to: window)

        return imageView
    }

    private func fallbackDismissal(fromView: UIView, context: UIViewControllerContextTransitioning) {
        UIView.animate(
            withDuration: transitionDuration(using: context),
            delay: 0,
            options: .curveEaseIn,
            animations: {
                fromView.alpha = 0
                fromView.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
            },
            completion: { _ in
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
        return false  // ✅ 关键：保留下层视图，这样下滑时可以看到
    }

    override func presentationTransitionWillBegin() {
        // 不添加 dimmingView，让 presentedViewController 自己控制背景
        guard let presentedView = presentedView else { return }
        presentedView.frame = frameOfPresentedViewInContainerView
    }

    override func containerViewWillLayoutSubviews() {
        super.containerViewWillLayoutSubviews()
        presentedView?.frame = frameOfPresentedViewInContainerView
    }
}