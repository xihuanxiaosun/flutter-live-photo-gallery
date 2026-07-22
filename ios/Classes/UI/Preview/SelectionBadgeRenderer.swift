import UIKit

/// 预览页选择徽标（圆圈勾选 / 序号）的纯绘制。从 PhotoPreviewPageViewController 抽出。
enum SelectionBadgeRenderer {

    /// 圆圈徽标：filled=已选（实心 + 白色对勾），否则空心白描边。
    static func circle(filled: Bool, color: UIColor) -> UIImage? {
        UIGraphicsImageRenderer(size: CGSize(width: 30, height: 30)).image { _ in
            if filled {
                color.setFill()
                let c = UIBezierPath(ovalIn: CGRect(x: 3, y: 3, width: 24, height: 24))
                c.fill()
                UIColor.white.setStroke()
                let check = UIBezierPath()
                check.move(to: CGPoint(x: 10, y: 15))
                check.addLine(to: CGPoint(x: 13, y: 18))
                check.addLine(to: CGPoint(x: 20, y: 11))
                check.lineWidth = 2
                check.lineCapStyle = .round
                check.stroke()
            } else {
                UIColor.white.setStroke()
                let c = UIBezierPath(ovalIn: CGRect(x: 3, y: 3, width: 24, height: 24))
                c.lineWidth = 2
                c.stroke()
            }
        }
    }

    /// 序号徽标：实心圆 + 居中白色数字。
    static func number(_ number: Int, color: UIColor) -> UIImage? {
        UIGraphicsImageRenderer(size: CGSize(width: 30, height: 30)).image { _ in
            color.setFill()
            UIBezierPath(ovalIn: CGRect(x: 3, y: 3, width: 24, height: 24)).fill()
            let text = "\(number)"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 14, weight: .bold),
                .foregroundColor: UIColor.white,
            ]
            let textSize = text.size(withAttributes: attributes)
            let textRect = CGRect(
                x: (30 - textSize.width) / 2,
                y: (30 - textSize.height) / 2,
                width: textSize.width,
                height: textSize.height
            )
            text.draw(in: textRect, withAttributes: attributes)
        }
    }
}
