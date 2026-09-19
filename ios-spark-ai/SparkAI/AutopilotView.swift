//
//  AutopilotView.swift
//  SparkAI
//
//  Mission control for the autonomous agent: queue goals, watch the
//  plan→execute workflow stream live, approve gated actions and manage the
//  auto-runner queue.
//

import SwiftUI

struct AutopilotView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var goal = ""

    private var autopilot: AutopilotService { .shared }

    var body: some View {
        VStack(spacing: 0) {
            header
            composer
            missionList
        }
        .background(Theme.bgPrimary)
    }

    // MARK: - Header

    private var runningMission: Mission? {
        autopilot.missions.first { $0.status == .running }
    }

    private var statusLine: String {
        if let running = runningMission {
            return running.isAwaitingApproval ? "AWAITING APPROVAL" : "EXECUTING MISSION"
        }
        let queued = autopilot.missions.filter { $0.status == .queued }.count
        return queued > 0 ? "ENGINE IDLE · \(queued) QUEUED" : "STANDBY"
    }

    private var statusColor: Color {
        if let running = runningMission {
            return running.isAwaitingApproval ? Theme.amber : Theme.blue
        }
        return autopilot.isEngineBusy ? Theme.blue : Theme.emerald
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "rocket")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Theme.amber)
                .frame(width: 32, height: 32)
                .background(Theme.amber.opacity(0.14), in: .rect(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.amber.opacity(0.3)))

            VStack(alignment: .leading, spacing: 1) {
                Text("AUTOPILOT")
                    .font(Theme.display(15, .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text(statusLine)
                    .font(Theme.mono(9.5, .semibold))
                    .foregroundStyle(statusColor)
                    .tracking(1)
            }

            Spacer()

            if autopilot.missions.contains(where: { $0.status != .queued && $0.status != .running }) {
                Button {
                    Haptics.light()
                    autopilot.clearFinished()
                } label: {
                    Text("CLEAR")
                        .font(Theme.mono(10, .heavy))
                        .tracking(1)
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
            }

            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .symbolEffect(.pulse, isActive: autopilot.isEngineBusy)
        }
        .padding(16)
        .background(.ultraThinMaterial.opacity(0.4))
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                toggleRow("AUTO-APPROVE", isOn: Binding(
                    get: { autopilot.isAutoApprove },
                    set: { autopilot.setAutoApprove($0) }
                ), tint: Theme.emerald)

                toggleRow("AUTO-RUNNER", isOn: Binding(
                    get: { autopilot.isAutoRun },
                    set: { autopilot.setAutoRun($0) }
                ), tint: Theme.amber)

                Spacer()
            }

            HStack(alignment: .bottom, spacing: 10) {
                TextField("Describe the mission…", text: $goal, axis: .vertical)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.textPrimary)
                    .tint(Theme.amber)
                    .lineLimit(1...4)

                if runningMission != nil {
                    Button {
                        autopilot.stopAll()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Theme.rose)
                            .frame(width: 38, height: 38)
                            .background(Theme.bgSurface, in: Circle())
                            .overlay(Circle().strokeBorder(Theme.rose.opacity(0.4)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop all missions")
                }

                Button {
                    autopilot.launch(goal)
                    goal = ""
                } label: {
                    Image(systemName: "rocket.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.bgPrimary)
                        .frame(width: 38, height: 38)
                        .background(goal.trimmingCharacters(in: .whitespaces).isEmpty ? Theme.bgElevated : Theme.amber, in: Circle())
                        .overlay(Circle().strokeBorder(Theme.border))
                }
                .buttonStyle(.plain)
                .disabled(goal.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityLabel("Launch mission")
            }

            if !autopilot.isAutoApprove {
                Text("AUTO-APPROVE OFF — every planned action waits for your yes/no before it runs.")
                    .font(Theme.mono(9, .semibold))
                    .foregroundStyle(Theme.amber)
                    .tracking(0.4)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.bgSurface)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func toggleRow(_ label: String, isOn: Binding<Bool>, tint: Color) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(Theme.mono(9, .heavy))
                .tracking(0.8)
                .foregroundStyle(isOn.wrappedValue ? tint : Theme.textTertiary)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(tint)
                .fixedSize()
        }
    }

    // MARK: - Mission list

    private var missionList: some View {
        ScrollView {
            VStack(spacing: 12) {
                if autopilot.missions.isEmpty {
                    emptyState
                } else {
                    ForEach(autopilot.missions) { mission in
                        MissionCard(mission: mission)
                    }
                }
            }
            .padding(16)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "rocket")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
            Text("Queue a mission — the agent plans each step with the AI mesh and executes it for real, auto-approved.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)

            VStack(spacing: 8) {
                ForEach(Self.exampleGoals, id: \.self) { example in
                    Button {
                        Haptics.light()
                        goal = example
                    } label: {
                        Text(example)
                            .font(Theme.mono(11.5))
                            .foregroundStyle(Theme.sky)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Theme.skyDim, in: .rect(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.sky.opacity(0.22)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 48)
        .padding(.horizontal, 6)
    }

    private static let exampleGoals = [
        "Run Featherless self-healing diagnostics to detect and auto-fix errors in the project",
        "Scan the signup form on my site and report every field it demands",
        "Create an account on a site I own — alias, password, inbox code, store the credential",
        "Fetch https://api.github.com/zen and summarize what it says",
    ]
}

// MARK: - Mission card

private struct MissionCard: View {
    let mission: Mission
    private var autopilot: AutopilotService { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            topRow

            Text(mission.goal)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            progress

            if !mission.steps.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(mission.steps) { step in
                        MissionStepRow(step: step)
                    }
                }
            }

            if !mission.summary.isEmpty {
                Text(mission.summary)
                    .font(Theme.mono(11.5))
                    .foregroundStyle(mission.status == .complete ? Theme.emerald : Theme.textSecondary)
                    .lineLimit(8)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(hex: 0x0C0C10), in: .rect(cornerRadius: 10))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bgSurface, in: .rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(cardBorder))
    }

    private var topRow: some View {
        HStack(spacing: 8) {
            Text(statusLabel)
                .font(Theme.mono(9, .heavy))
                .tracking(1)
                .foregroundStyle(statusColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(statusColor.opacity(0.13), in: .capsule)

            Text(mission.createdAt.formatted(.relative(presentation: .named)))
                .font(Theme.mono(10))
                .foregroundStyle(Theme.textTertiary)

            Spacer()

            if mission.status == .queued {
                cardButton("play.fill", tint: Theme.emerald) { autopilot.runNow(mission.id) }
            }
            if mission.status == .running {
                cardButton("stop.fill", tint: Theme.rose) { autopilot.stopAll() }
            }
            if mission.status != .running {
                cardButton("trash", tint: Theme.textTertiary) { autopilot.remove(mission.id) }
            }
        }
    }

    private func cardButton(_ icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(Theme.bgElevated, in: .rect(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var progress: some View {
        if mission.status == .running {
            ProgressView()
                .progressViewStyle(.linear)
                .tint(mission.isAwaitingApproval ? Theme.amber : Theme.blue)
        } else if mission.status == .complete {
            ProgressView(value: 1)
                .progressViewStyle(.linear)
                .tint(Theme.emerald)
        }

        if !mission.steps.isEmpty {
            Text("\(mission.steps.count) STEPS · \(mission.errorCount) ERROR\(mission.errorCount == 1 ? "" : "S")")
                .font(Theme.mono(9, .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private var statusLabel: String {
        switch mission.status {
        case .queued: "QUEUED"
        case .running: mission.isAwaitingApproval ? "AWAITING APPROVAL" : "RUNNING"
        case .complete: "COMPLETE"
        case .failed: "FAILED"
        case .stopped: "STOPPED"
        }
    }

    private var statusColor: Color {
        switch mission.status {
        case .queued: Theme.amber
        case .running: mission.isAwaitingApproval ? Theme.amber : Theme.blue
        case .complete: Theme.emerald
        case .failed: Theme.rose
        case .stopped: Theme.textTertiary
        }
    }

    private var cardBorder: Color {
        mission.status == .running ? Theme.blue.opacity(0.35) : Theme.border
    }
}

// MARK: - Step row

private struct MissionStepRow: View {
    let step: MissionStep
    private var autopilot: AutopilotService { .shared }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            icon
                .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(Theme.mono(11, .bold))
                    .foregroundStyle(titleColor)

                if !step.detail.isEmpty {
                    Text(step.detail)
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if step.status == .awaiting {
                    HStack(spacing: 8) {
                        Button {
                            autopilot.approve(step.id)
                        } label: {
                            Text("APPROVE")
                                .font(Theme.mono(10, .heavy))
                                .foregroundStyle(Theme.bgPrimary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Theme.emerald, in: .capsule)
                        }
                        .buttonStyle(.plain)

                        Button {
                            autopilot.reject(step.id)
                        } label: {
                            Text("REJECT")
                                .font(Theme.mono(10, .heavy))
                                .foregroundStyle(Theme.rose)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Theme.rose.opacity(0.12), in: .capsule)
                                .overlay(Capsule().strokeBorder(Theme.rose.opacity(0.4)))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 4)
                }
            }

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch step.status {
        case .running:
            ProgressView().tint(Theme.blue).scaleEffect(0.7)
        case .ok:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.emerald)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.rose)
        case .awaiting:
            Image(systemName: "hourglass")
                .font(.system(size: 12))
                .foregroundStyle(Theme.amber)
        case .skipped:
            Image(systemName: "minus.circle")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private var titleColor: Color {
        switch step.status {
        case .ok: Theme.emerald
        case .failed: Theme.rose
        case .awaiting: Theme.amber
        case .running: Theme.blue
        case .skipped: Theme.textTertiary
        }
    }
}

#Preview {
    AutopilotView()
        .preferredColorScheme(.dark)
}
