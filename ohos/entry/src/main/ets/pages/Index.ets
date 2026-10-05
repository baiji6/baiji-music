// 白姬音乐 —— 鸿蒙壳启动页（与 Flutter 侧暗色玻璃拟态 + 霓虹渐变主题一致）
@Entry
@Component
struct Index {
  @State message: string = '白姬音乐';

  build() {
    Stack({ alignContent: Alignment.Center }) {
      // 霓虹渐变背景
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 135,
          colors: [
            ['#0B0E1A', 0.0],
            ['#160F33', 0.5],
            ['#2A0E3F', 1.0]
          ]
        })

      BlurView()
        .width('100%')
        .height('100%')
        .opacity(0.18)

      Column({ space: 14 }) {
        Text(this.message)
          .fontSize(40)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
          .textShadow({
            radius: 24,
            color: '#A855F7',
            offsetX: 0,
            offsetY: 0
          })

        Text('跨 iOS / macOS / Windows / Linux / Android / HarmonyOS')
          .fontSize(13)
          .fontColor('#9CA3C8')

        Text('未来感 · 玻璃拟态 · 六端同源')
          .fontSize(12)
          .fontColor('#6E7298')
      }
    }
    .width('100%')
    .height('100%')
  }
}

@Component
struct BlurView {
  build() {
    // 模拟玻璃拟态：径向渐变高光层
    Column()
      .width('100%')
      .height('100%')
      .linearGradient({
        angle: 0,
        colors: [
          ['#00FFFFFF', 0.0],
          ['#00FFFFFF', 0.7],
          ['#1AA855F7', 1.0]
        ]
      })
  }
}