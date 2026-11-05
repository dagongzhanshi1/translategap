import SwiftUI

struct MiniCard: View {
    @ObservedObject var store: TutorStore
    var settings: () -> Void
    var records: () -> Void
    var details: () -> Void
    var hide: () -> Void
    var snooze: () -> Void
    var body: some View {
        ZStack { Backdrop(); VStack(spacing: 4) {
            HStack(spacing: 4) { Text("译隙").font(.system(size: 10, weight: .semibold)); Text("今日 \(store.todayCount) 句").font(.system(size: 8.5)).foregroundStyle(Palette.muted); Spacer(minLength: 2)
                IconButton(symbol: "clock.arrow.circlepath", label: "练习记录", action: records)
                IconButton(symbol: "slider.horizontal.3", label: "偏好设置 · ⌘,", action: settings)
                IconButton(symbol: "xmark", label: "收起 · Esc", action: hide)
            }.frame(height: 18)
            if let attempt = store.cardDetail {
                MiniAttemptDetail(store: store, attempt: attempt, close: details)
            } else if !store.keyAvailable { setup }
            else if let exercise = store.state.current {
                if store.state.feedbackVisible, let result = store.currentResult { feedback(result) } else { writing(exercise) }
            } else { preparation }
        }.padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading) }.foregroundStyle(Palette.ink).tint(Palette.accent).frame(width: CardPlacement.size.width, height: CardPlacement.size.height)
        .transaction { $0.animation = nil }
    }
    func writing(_ exercise: Exercise) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(exercise.direction.title + " · " + exercise.difficulty).font(.system(size: 8.5, weight: .medium)).foregroundStyle(Palette.accent); Spacer(minLength: 4); Text(exercise.sourceBadge).font(.system(size: 7.5)).foregroundStyle(Palette.muted).lineLimit(1).help(exercise.sourceDescription) }
            Text(exercise.source).font(.system(size: 12, weight: .medium)).lineSpacing(1).lineLimit(3).minimumScaleFactor(0.8).frame(maxWidth: .infinity, minHeight: 40, maxHeight: 40, alignment: .topLeading).textSelection(.enabled)
            ZStack(alignment: .topLeading) {
                if store.state.draft.isEmpty {
                    Text("在这里写译文…").font(.system(size: AnswerEditor.fontSize)).foregroundStyle(Palette.muted.opacity(0.8))
                        .padding(.leading, AnswerEditor.outerInset + AnswerEditor.textInset).padding(.top, AnswerEditor.outerInset + AnswerEditor.textInset).allowsHitTesting(false)
                }
                AnswerEditor(text: Binding(get: { store.state.draft }, set: store.updateDraft), enabled: !store.grading, submit: store.submit).padding(AnswerEditor.outerInset)
            }.frame(height: 43).background(RoundedRectangle(cornerRadius: 8).fill(Palette.ink.opacity(0.04))).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line.opacity(0.27), lineWidth: 0.5))
            HStack { Button("延后 30 分", action: snooze).buttonStyle(.plain).font(.system(size: 9)).foregroundStyle(Palette.muted); Spacer()
                if store.grading { ProgressView().controlSize(.mini) }
                Button(store.grading ? "正在评分…" : "提交 ↵", action: store.submit).buttonStyle(QuietButton(primary: true, compact: true)).disabled(!store.canSubmit)
            }.frame(height: 22)
            HStack { if !store.notice.isEmpty { Text(store.notice).foregroundStyle(Palette.gold).lineLimit(1).help(store.notice) } else { Text("⌘L 打开 / 收起"); Spacer(); Button(store.generating && store.readyCount == 0 ? "准备中…" : "换一句 ⌘N", action: store.next).buttonStyle(.plain).disabled(store.generating && store.readyCount == 0) } }.font(.system(size: 8)).foregroundStyle(Palette.muted).lineLimit(1).frame(height: 12, alignment: .topLeading)
        }
    }
    func feedback(_ attempt: Attempt) -> some View {
        let grade = attempt.assessment
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 3) {
                Text("\(grade.score)").font(.system(size: 22, weight: .medium, design: .rounded)).foregroundStyle(grade.strong ? Palette.success : Palette.accent)
                Text("/ \(grade.maximumScore)").font(.system(size: 9)).foregroundStyle(Palette.muted)
                Spacer(minLength: 2)
                if grade.isDetailed {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("原意 \(grade.accuracy)/60 · 语法 \(grade.grammar)/20")
                        Text("自然 \(grade.naturalness)/15 · 书写 \(grade.mechanics ?? 0)/5")
                    }.font(.system(size: 7.5)).monospacedDigit().foregroundStyle(Palette.muted)
                } else {
                    VStack(alignment: .trailing, spacing: 2) { Text("旧版 · 10 分制").font(.system(size: 8)); Text(grade.summary).font(.system(size: 7.5)).foregroundStyle(Palette.muted) }
                }
            }.frame(height: 27)
            Text(grade.feedback).font(.system(size: 10.5, weight: .medium)).lineSpacing(1).lineLimit(2).minimumScaleFactor(0.9).frame(maxWidth: .infinity, minHeight: 26, maxHeight: 26, alignment: .topLeading)
            VStack(alignment: .leading, spacing: 2) { Text("一个参考译法").font(.system(size: 8)).foregroundStyle(Palette.muted); Text(grade.reference).font(.system(size: 11)).lineSpacing(1).lineLimit(3).minimumScaleFactor(0.8).frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34, alignment: .topLeading).textSelection(.enabled) }
            HStack(spacing: 6) { Button("修改 ⌘E", action: store.revise).buttonStyle(QuietButton(compact: true)); Button("明细 ⌘I", action: details).buttonStyle(.plain).font(.system(size: 9)).foregroundStyle(Palette.muted); Spacer(minLength: 0); Button(store.generating && store.readyCount == 0 ? "准备中…" : "下一句 ↵", action: store.next).buttonStyle(QuietButton(primary: true, compact: true)).disabled(store.generating && store.readyCount == 0) }.frame(height: 22)
            Text(store.notice.isEmpty ? (attempt.exercise.sourceBadge + (attempt.revision ? " · 修改后 · AI 评分" : " · 首次 · AI 评分")) : store.notice).font(.system(size: 8)).foregroundStyle(store.notice.isEmpty ? Palette.muted : Palette.gold).lineLimit(1).frame(height: 11, alignment: .topLeading)
        }
    }
    var setup: some View { VStack(spacing: 8) { Spacer(minLength: 0); Text("一句话，慢慢练。").font(.system(size: 16, weight: .medium)); Text("连接 DeepSeek，就能开始\n中英互译的小练习。").font(.system(size: 10.5)).foregroundStyle(Palette.muted).multilineTextAlignment(.center).lineSpacing(4); Button("连接 API", action: settings).buttonStyle(QuietButton(primary: true, compact: true)); Spacer(minLength: 0); Text("按 ⌘L 随时打开 / 收起").font(.system(size: 9)).foregroundStyle(Palette.muted) }.frame(maxWidth: .infinity, maxHeight: .infinity) }
    var preparation: some View { VStack(spacing: 8) { Spacer(minLength: 0); if store.generating { ProgressView().controlSize(.small); Text("正在准备第一句…").font(.system(size: 11)); Text("每题一句，提前缓存。").font(.system(size: 10)).foregroundStyle(Palette.muted) } else { Text("先准备一句话。").font(.system(size: 14, weight: .medium)); Text(store.generationError.isEmpty ? "接下来可以用键盘完成整次练习。" : store.generationError).font(.system(size: 10)).lineSpacing(3).multilineTextAlignment(.center).foregroundStyle(Palette.muted); Button("重新出题") { store.prefetch(force: true) }.buttonStyle(QuietButton(primary: true, compact: true)) }; Spacer(minLength: 0); Text("后台等待时，可以先收起卡片。").font(.system(size: 9)).foregroundStyle(Palette.muted) }.frame(maxWidth: .infinity, maxHeight: .infinity) }
}

struct WorkspaceView: View {
    @ObservedObject var store: TutorStore
    var export: () -> Void
    var closeDetail: (() -> Void)? = nil
    @State private var key = ""
    @State private var confirmClearHistory = false
    var body: some View { ZStack { Backdrop(workspace: true); VStack(spacing: 0) {
        WorkspaceChrome()
        if store.workspaceTab == 1, !store.detailReturnsToCard, let attempt = store.selectedAttempt {
            PagedAttemptDetail(store: store, attempt: attempt, close: { if let closeDetail { closeDetail() } else { store.closeDetail() } })
        } else {
            HStack { Text(store.workspaceTab == 0 ? "偏好设置" : (store.workspaceTab == 1 ? "练习记录" : "使用说明")).font(.system(size: 19, weight: .semibold)); Spacer(); Text("译隙").font(.system(size: 11)).foregroundStyle(Palette.muted) }.padding(.horizontal, 22).padding(.top, 17).padding(.bottom, 13)
            OptionStrip(selection: $store.workspaceTab, options: [("偏好设置", 0), ("练习记录", 1), ("使用说明", 2)], label: "页面").padding(.horizontal, 22).padding(.bottom, 16)
            if store.workspaceTab == 1, !store.historyNotice.isEmpty {
                HStack { Text(store.historyNotice).foregroundStyle(Palette.muted); Spacer(); if store.recordUndoCount > 0 { Button("撤销 ⌘Z", action: store.undoRecordDeletion).buttonStyle(.plain).foregroundStyle(Palette.accent) } }.font(.system(size: 11)).padding(.horizontal, 24).padding(.bottom, 12)
            }
            ScrollView { Group { if store.workspaceTab == 0 { preferences } else if store.workspaceTab == 1 { history } else { help } }.padding(.horizontal, 24).padding(.bottom, 24).frame(maxWidth: .infinity, alignment: .leading) }
        }
    } }.foregroundStyle(Palette.ink).tint(Palette.accent).frame(minWidth: 500, minHeight: 510)
        .onChange(of: store.state.preferences) { _ in store.preferencesChanged() }
        .confirmationDialog("清空全部练习记录？", isPresented: $confirmClearHistory) {
            Button("清空全部记录", role: .destructive) { store.deleteRecords(Set(store.state.attempts.map(\.id))) }
            Button("取消", role: .cancel) {}
        } message: { Text("只删除练习与评分记录，设置、当前题目和草稿保留。删除后可用 ⌘Z 撤销。") }
    }
    var preferences: some View { VStack(alignment: .leading, spacing: 14) {
        SettingsGroup(title: "练习安排") {
            Toggle("定时浮现小卡片", isOn: $store.state.preferences.reminders).toggleStyle(.switch)
            HStack { Text("间隔"); Spacer(); Picker("间隔", selection: $store.state.preferences.intervalMinutes) { ForEach([30, 60, 90, 120, 180, 240], id: \.self) { Text($0 < 60 ? "\($0) 分钟" : ($0 % 60 == 0 ? "\($0 / 60) 小时" : "\($0) 分钟")).tag($0) } }.labelsHidden().frame(width: 150) }
            Text("默认 1 小时一次。提示不抢输入焦点，15 秒后自动收起；已输入的译文不会被覆盖。忙时可延后 30 分钟。").font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(4)
            OptionStrip(selection: $store.state.preferences.direction, options: [("中英交替", "alternating"), ("中译英", "zhToEn"), ("英译中", "enToZh")], label: "翻译方向")
            OptionStrip(selection: Binding(get: { store.state.preferences.effectiveExamTrack }, set: { store.state.preferences.examTrack = $0 }), options: [("六级", ExamTrack.cet6), ("雅思表达", ExamTrack.ielts), ("混合", ExamTrack.mixed)], label: "考试参考")
            Text("新题会标注真题节选、改编练习或原创仿题。真题只用已核对原句；雅思官方样题用于改编，明细可查看出处。").font(.system(size: 10)).foregroundStyle(Palette.muted).lineSpacing(4)
            HStack { Picker("难度", selection: $store.state.preferences.difficulty) { ForEach(["简单", "适中", "进阶"], id: \.self) { Text($0) } }; Picker("主题", selection: $store.state.preferences.topic) { ForEach(["混合", "日常", "学习", "工作", "科技", "财经"], id: \.self) { Text($0) } } }
            Text("难度调整表达与语法，每次仍然只出一个短句。当前题保留，新设置从下一句生效。").font(.system(size: 10)).foregroundStyle(Palette.muted).lineSpacing(4)
        }
        SettingsGroup(title: "联网找题") {
            Toggle("按需自动补充材料", isOn: Binding(get: { store.state.preferences.effectiveAutomaticMaterials }, set: { store.state.preferences.automaticMaterials = $0 })).toggleStyle(.switch)
            HStack { Text("本机 \(store.allMaterials.count) 份参考材料"); Spacer(); Button(store.fetchingMaterials ? "补充中…" : "补充一批") { store.refreshMaterialsIfNeeded(forced: true) }.buttonStyle(QuietButton(compact: true)).disabled(store.fetchingMaterials || store.grading || !store.keyAvailable) }
            Text(store.materialStatus).font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(4)
            Text("可用材料不足6份时后台补充，每批最多搜索2次、抓取4页，每日最多4批。先核对原文再缓存，不影响当前题与草稿。搜索、抓取及整理按 DeepSeek API 计费。").font(.system(size: 10)).foregroundStyle(Palette.muted).lineSpacing(4)
        }
        SettingsGroup(title: "外观") {
            OptionStrip(selection: $store.state.preferences.appearance, options: [("跟随系统", "system"), ("浅色", "light"), ("深色", "dark")], label: "配色")
            Toggle("液态玻璃", isOn: $store.state.preferences.glass).toggleStyle(.switch)
            HStack { Text("玻璃程度"); Slider(value: $store.state.preferences.glassAmount, in: 0...1); Text("\(Int(store.state.preferences.glassAmount * 100))%").font(.system(size: 10)).monospacedDigit().frame(width: 32) }.disabled(!store.state.preferences.glass)
            Toggle("卡片置顶", isOn: $store.state.preferences.pinned).toggleStyle(.switch)
        }
        SettingsGroup(title: "DeepSeek 连接") {
            HStack { Circle().fill(store.keyAvailable ? Palette.success : Palette.gold).frame(width: 6, height: 6); Text(store.keyAvailable ? "API Key 已存入本机钥匙串" : "尚未设置 API Key").font(.system(size: 11)) }
            HStack { SecureField("填写新 API Key，留空则保留现有 Key", text: $key).textFieldStyle(.roundedBorder); Button("保存") { store.saveKey(key); if store.keyAvailable { key = "" } }.buttonStyle(QuietButton()).disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            HStack { Picker("模型", selection: $store.state.preferences.model) { ForEach(store.models, id: \.self) { Text($0) } }; Button(store.testingConnection ? "连接中…" : "测试连接", action: store.testConnection).buttonStyle(QuietButton()).disabled(store.testingConnection || !store.keyAvailable) }
            if !store.connection.isEmpty { Text(store.connection).font(.system(size: 11)).foregroundStyle(Palette.muted).textSelection(.enabled) }
            Text("官方接口 api.deepseek.com。出题与评分会发送练习内容和你的译文；API 按 DeepSeek 账户计费。Key 不写入源码、练习记录或导出文件。").font(.system(size: 10)).lineSpacing(4).foregroundStyle(Palette.muted)
        }
    }.font(.system(size: 12)) }
    var history: some View { VStack(alignment: .leading, spacing: 14) {
        HStack { metric("完成练习", "\(store.firstAttempts.count) 句"); metric("修改尝试", "\(store.revisionCount) 次"); Spacer(); Button("导出 CSV", action: export).buttonStyle(QuietButton()).disabled(store.state.attempts.isEmpty) }
        HStack(spacing: 12) {
            Text("全部记录 · \(store.state.attempts.count) 条").font(.system(size: 11, weight: .medium))
            Spacer()
            Button(store.managingHistory ? "完成" : "选择") { store.managingHistory.toggle(); if !store.managingHistory { store.selectedHistoryIDs = [] } }.buttonStyle(.plain).foregroundStyle(Palette.accent).disabled(store.state.attempts.isEmpty && !store.managingHistory)
            Button("清空") { confirmClearHistory = true }.buttonStyle(.plain).foregroundStyle(Palette.muted).disabled(store.state.attempts.isEmpty)
        }.font(.system(size: 11))
        if store.managingHistory, !store.state.attempts.isEmpty {
            HStack {
                Button(store.selectedHistoryIDs.count == store.state.attempts.count ? "取消全选" : "全选") { store.selectedHistoryIDs = store.selectedHistoryIDs.count == store.state.attempts.count ? [] : Set(store.state.attempts.map(\.id)) }.buttonStyle(.plain).foregroundStyle(Palette.accent)
                Text("已选 \(store.selectedHistoryIDs.count) 条").foregroundStyle(Palette.muted); Spacer()
                Button("删除所选") { store.deleteRecords(store.selectedHistoryIDs) }.buttonStyle(QuietButton(compact: true)).disabled(store.selectedHistoryIDs.isEmpty)
            }.font(.system(size: 11))
        }
        if store.state.attempts.isEmpty { Text("写完第一句，记录就会出现在这里。\n首次作答和修改分别记录，不会重复增加完成句数。").font(.system(size: 12)).lineSpacing(5).foregroundStyle(Palette.muted).padding(.vertical, 24) }
        else {
            SettingsGroup(title: "首次得分 · 按方向、难度、模型和评分规则分组") {
                ForEach(scoreGroups, id: \.label) { group in HStack { Text(group.label).font(.system(size: 10)); Spacer(); Text(String(format: "%.1f / %d · %d 句", group.average, group.maximumScore, group.count)).font(.system(size: 11)).monospacedDigit() } }
            }
            LazyVStack(spacing: 8) {
                ForEach(Array(store.state.attempts.reversed())) { attempt in
                    HStack(spacing: 10) {
                        if store.managingHistory {
                            Toggle("选择记录", isOn: Binding(get: { store.selectedHistoryIDs.contains(attempt.id) }, set: { if $0 { store.selectedHistoryIDs.insert(attempt.id) } else { store.selectedHistoryIDs.remove(attempt.id) } })).toggleStyle(.checkbox).labelsHidden()
                        }
                        Button { store.openDetail(attempt) } label: {
                            HStack(alignment: .top, spacing: 10) {
                                VStack(spacing: 2) { Text("\(attempt.assessment.score)").font(.system(size: 22, weight: .medium, design: .rounded)); Text("/ \(attempt.assessment.maximumScore)").font(.system(size: 9)).foregroundStyle(Palette.muted) }.foregroundStyle(Palette.accent).frame(width: 44)
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack { Text(attempt.exercise.direction.title + (attempt.revision ? " · 修改" : " · 首次") + " · " + (attempt.exercise.verifiedProvenance?.kind.title ?? "未标注")).font(.system(size: 10, weight: .medium)).lineLimit(1).help(attempt.exercise.sourceDescription); Spacer(); Text(attempt.date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 9)).foregroundStyle(Palette.muted) }
                                    Text(attempt.exercise.source).font(.system(size: 12)).lineLimit(2).multilineTextAlignment(.leading)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        IconButton(symbol: "trash", label: "删除这条记录 · ⌘Z 可撤销") { store.deleteRecords([attempt.id]) }
                    }.padding(12).background(RoundedRectangle(cornerRadius: 12).fill(Palette.ink.opacity(0.035)))
                }
            }
        }
        Text("删除会同步更新统计；误删可用 ⌘Z 撤销。本次退出后撤销历史清除。").font(.system(size: 10)).foregroundStyle(Palette.muted).lineSpacing(4)
    } }
    struct ScoreGroup { var label: String; var average: Double; var count: Int; var maximumScore: Int }
    var scoreGroups: [ScoreGroup] { let groups = Dictionary(grouping: store.firstAttempts) { $0.exercise.direction.title + " · " + $0.exercise.difficulty + " · " + $0.model + " · v" + $0.assessment.rubricIdentifier }; return groups.keys.sorted().map { key in let values = groups[key]!; return ScoreGroup(label: key, average: Double(values.reduce(0) { $0 + $1.assessment.score }) / Double(values.count), count: values.count, maximumScore: values[0].assessment.maximumScore) } }
    func metric(_ label: String, _ value: String) -> some View { VStack(alignment: .leading, spacing: 5) { Text(label).font(.system(size: 10)).foregroundStyle(Palette.muted); Text(value).font(.system(size: 23, weight: .medium, design: .rounded)) }.frame(maxWidth: .infinity, alignment: .leading) }
    var help: some View { VStack(alignment: .leading, spacing: 16) {
        Text("只练一句，写完再继续。").font(.system(size: 24, weight: .medium))
        Text("1. 看原句，在卡片里写下译文。\n2. 按回车提交，看看一个最值得改的地方。\n3. ⌘E 修改，或回车进入下一句。").font(.system(size: 13)).lineSpacing(8)
        SettingsGroup(title: "键盘操作") { ForEach([("⌘L", "全局打开 / 收起；提示卡片上开始作答"), ("回车 / ⌘↵", "提交；反馈页进入下一句"), ("⇧↵", "在译文中换行"), ("⌘E", "修改刚才的译文"), ("⌘I", "打开 / 关闭明细，返回原来的页面"), ("← → / ⌘1、2、3", "卡片明细切换纠错、对照、更多"), ("↑ ↓ / Page Up、Down", "卡片正文滚动；空格向下，⇧空格向上"), ("Delete / ⌘⌫", "删除全部记录中已勾选的项目"), ("⌘Z", "在记录页面撤销删除"), ("⌘N", "下一句；未提交译文会被保留"), ("⌘D", "延后 30 分钟并收起"), ("⌘,", "打开偏好设置"), ("Esc", "收起卡片，保留译文")], id: \.0) { key, text in HStack(alignment: .top) { Text(key).font(.system(size: 11, weight: .medium, design: .monospaced)).frame(width: 75, alignment: .leading); Text(text).font(.system(size: 11)); Spacer() } } }
        SettingsGroup(title: "练习与记录") { Text("每题由 DeepSeek 生成并评分，接受合理的不同译法。新版满分100：内容与原意60、语法20、自然表达15、书写5。详情列出逐项扣分、原片段和建议改法；首次成绩保留，修改另记。旧版10分制按原口径单独展示。参考译法只是一个例子。\n\n后台提前缓存4句；缓存足够时不请求出题。每次提交请求一次评分。联网失败时保留草稿，可重试；不会用预设分数冒充模型结果。").font(.system(size: 11)).lineSpacing(5) }
        Text("数据保存在本机 TranslateGap 文件夹。默认每小时提示一次，锁屏或休眠后重新计时。卡片固定244×190点，当前题明细在卡片内分类、连续阅读，历史记录与设置在独立窗口。与词隙分开运行。").font(.system(size: 11)).lineSpacing(5).foregroundStyle(Palette.muted)
    } }
}
