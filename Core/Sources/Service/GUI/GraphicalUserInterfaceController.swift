import AppKit
import ChatGPTChatTab
import ChatTab
import ComposableArchitecture
import Dependencies
import Environment
import Preferences
import SuggestionWidget

#if canImport(ChatTabPersistent)
import ChatTabPersistent
#endif

struct GUI: ReducerProtocol {
    struct State: Equatable {
        var suggestionWidgetState = WidgetFeature.State()

        var chatTabGroup: ChatPanelFeature.ChatTabGroup {
            get { suggestionWidgetState.chatPanelState.chatTapGroup }
            set { suggestionWidgetState.chatPanelState.chatTapGroup = newValue }
        }

        #if canImport(ChatTabPersistent)
        var persistentState: ChatTabPersistent.State {
            get {
                .init(chatTabInfo: suggestionWidgetState.chatPanelState.chatTapGroup.tabInfo)
            }
            set {
                suggestionWidgetState.chatPanelState.chatTapGroup.tabInfo = newValue.chatTabInfo
            }
        }
        #endif
    }

    enum Action {
        case openChatPanel(forceDetach: Bool)
        case createChatGPTChatTabIfNeeded
        case sendCustomCommandToActiveChat(CustomCommand)

        case suggestionWidget(WidgetFeature.Action)

        #if canImport(ChatTabPersistent)
        case persistent(ChatTabPersistent.Action)
        #endif
    }

    @Dependency(\.chatTabPool) var chatTabPool: ChatTabPool

    var body: some ReducerProtocol<State, Action> {
        Scope(state: \.suggestionWidgetState, action: /Action.suggestionWidget) {
            WidgetFeature()
        }

        Scope(
            state: \.chatTabGroup,
            action: /Action.suggestionWidget .. /WidgetFeature.Action.chatPanel
        ) {
            Reduce { _, action in
                switch action {
                case let .createNewTapButtonClicked(kind):
                    return .run { send in
                        if let (_, chatTabInfo) = await chatTabPool.createTab(for: kind) {
                            await send(.appendAndSelectTab(chatTabInfo))
                        }
                    }

                case let .closeTabButtonClicked(id):
                    return .run { _ in
                        chatTabPool.removeTab(of: id)
                    }

                case let .chatTab(_, .openNewTab(builder)):
                    return .run { send in
                        if let (_, chatTabInfo) = await chatTabPool
                            .createTab(from: builder.chatTabBuilder)
                        {
                            await send(.appendAndSelectTab(chatTabInfo))
                        }
                    }

                default:
                    return .none
                }
            }
        }

        #if canImport(ChatTabPersistent)
        Scope(state: \.persistentState, action: /Action.persistent) {
            ChatTabPersistent()
        }
        #endif

        Reduce { state, action in
            switch action {
            case let .openChatPanel(forceDetach):
                return .run { send in
                    await send(
                        .suggestionWidget(.chatPanel(.presentChatPanel(forceDetach: forceDetach)))
                    )
                }

            case .createChatGPTChatTabIfNeeded:
                if state.chatTabGroup.tabInfo.contains(where: {
                    chatTabPool.getTab(of: $0.id) is ChatGPTChatTab
                }) {
                    return .none
                }
                return .run { send in
                    if let (_, chatTabInfo) = await chatTabPool.createTab(for: nil) {
                        await send(.suggestionWidget(.chatPanel(.appendAndSelectTab(chatTabInfo))))
                    }
                }

            case let .sendCustomCommandToActiveChat(command):
                @Sendable func stopAndHandleCommand(_ tab: ChatGPTChatTab) async {
                    if tab.service.isReceivingMessage {
                        await tab.service.stopReceivingMessage()
                    }
                    try? await tab.service.handleCustomCommand(command)
                }

                if let info = state.chatTabGroup.selectedTabInfo,
                   let activeTab = chatTabPool.getTab(of: info.id) as? ChatGPTChatTab
                {
                    return .run { send in
                        await send(.openChatPanel(forceDetach: false))
                        await stopAndHandleCommand(activeTab)
                    }
                }

                if let info = state.chatTabGroup.tabInfo.first(where: {
                    chatTabPool.getTab(of: $0.id) is ChatGPTChatTab
                }),
                    let chatTab = chatTabPool.getTab(of: info.id) as? ChatGPTChatTab
                {
                    state.chatTabGroup.selectedTabId = chatTab.id
                    return .run { send in
                        await send(.openChatPanel(forceDetach: false))
                        await stopAndHandleCommand(chatTab)
                    }
                }

                return .run { send in
                    guard let (chatTab, chatTabInfo) = await chatTabPool.createTab(for: nil) else {
                        return
                    }
                    await send(.suggestionWidget(.chatPanel(.appendAndSelectTab(chatTabInfo))))
                    await send(.openChatPanel(forceDetach: false))
                    if let chatTab = chatTab as? ChatGPTChatTab {
                        await stopAndHandleCommand(chatTab)
                    }
                }

            case let .suggestionWidget(.chatPanel(.chatTab(id, .tabContentUpdated))):
                #if canImport(ChatTabPersistent)
                // when a tab is updated, persist it.
                return .run { send in
                    await send(.persistent(.chatTabUpdated(id: id)))
                }
                #else
                return .none
                #endif

            case let .suggestionWidget(.chatPanel(.closeTabButtonClicked(id))):
                #if canImport(ChatTabPersistent)
                // when a tab is closed, remove it from persistence.
                return .run { send in
                    await send(.persistent(.chatTabClosed(id: id)))
                }
                #else
                return .none
                #endif

            case .suggestionWidget:
                return .none

            #if canImport(ChatTabPersistent)
            case .persistent:
                return .none
            #endif
            }
        }
    }
}

@MainActor
public final class GraphicalUserInterfaceController {
    public static let shared = GraphicalUserInterfaceController()
    private let store: StoreOf<GUI>
    let widgetController: SuggestionWidgetController
    let widgetDataSource: WidgetDataSource
    let viewStore: ViewStoreOf<GUI>
    let chatTabPool: ChatTabPool

    class WeakStoreHolder {
        weak var store: StoreOf<GUI>?
    }

    private init() {
        let chatTabPool = ChatTabPool()
        let suggestionDependency = SuggestionWidgetControllerDependency()
        let setupDependency: (inout DependencyValues) -> Void = { dependencies in
            dependencies.suggestionWidgetControllerDependency = suggestionDependency
            dependencies.suggestionWidgetUserDefaultsObservers = .init()
            dependencies.chatTabPool = chatTabPool
            dependencies.chatTabBuilderCollection = ChatTabFactory.chatTabBuilderCollection

            #if canImport(ChatTabPersistent) && canImport(ProChatTab)
            dependencies.restoreChatTabInPool = chatTabPool.restore
            #endif
        }
        let store = StoreOf<GUI>(
            initialState: .init(),
            reducer: GUI(),
            prepareDependencies: setupDependency
        )
        self.store = store
        self.chatTabPool = chatTabPool
        viewStore = ViewStore(store)
        widgetDataSource = .init()

        widgetController = SuggestionWidgetController(
            store: store.scope(
                state: \.suggestionWidgetState,
                action: GUI.Action.suggestionWidget
            ),
            chatTabPool: chatTabPool,
            dependency: suggestionDependency
        )

        chatTabPool.createStore = { id in
            store.scope(
                state: { state in
                    state.chatTabGroup.tabInfo[id: id]
                        ?? .init(id: id, title: "")
                },
                action: { childAction in
                    .suggestionWidget(.chatPanel(.chatTab(id: id, action: childAction)))
                }
            )
        }

        suggestionDependency.suggestionWidgetDataSource = widgetDataSource
        suggestionDependency.onOpenChatClicked = { [weak self] in
            Task { [weak self] in
                await self?.viewStore.send(.createChatGPTChatTabIfNeeded).finish()
                self?.viewStore.send(.openChatPanel(forceDetach: false))
            }
        }
        suggestionDependency.onCustomCommandClicked = { command in
            Task {
                let commandHandler = PseudoCommandHandler()
                await commandHandler.handleCustomCommand(command)
            }
        }
    }

    public func openGlobalChat() {
        Task {
            await self.viewStore.send(.createChatGPTChatTabIfNeeded).finish()
            viewStore.send(.openChatPanel(forceDetach: true))
        }
    }
}

extension ChatTabPool {
    @MainActor
    func createTab(
        from builder: ChatTabBuilder
    ) async -> (any ChatTab, ChatTabInfo)? {
        let id = UUID().uuidString
        let info = ChatTabInfo(id: id, title: "")
        guard let chatTap = await builder.build(store: createStore(id)) else { return nil }
        setTab(chatTap)
        return (chatTap, info)
    }

    @MainActor
    func createTab(
        for kind: ChatTabKind?
    ) async -> (any ChatTab, ChatTabInfo)? {
        let id = UUID().uuidString
        let info = ChatTabInfo(id: id, title: "")
        guard let builder = kind?.builder else {
            let chatTap = ChatGPTChatTab(store: createStore(id))
            setTab(chatTap)
            return (chatTap, info)
        }

        guard let chatTap = await builder.build(store: createStore(id)) else { return nil }
        setTab(chatTap)
        return (chatTap, info)
    }

    #if canImport(ChatTabPersistent) && canImport(ProChatTab)
    @MainActor
    func restore(
        _ data: ChatTabPersistent.RestorableTabData
    ) async throws -> (any ChatTab, ChatTabInfo)? {
        let info = ChatTabInfo(id: data.id, title: "")
        switch data.name {
        case ChatGPTChatTab.name:
            guard let builder = try? await ChatGPTChatTab.restore(
                from: data.data,
                externalDependency: ()
            ) else { break }
            return createTab(from: builder)
        case BrowserChatTab.name:
            guard let builder = try? await BrowserChatTab.restore(
                from: data.data,
                externalDependency: ()
            ) else { break }
            return createTab(from: builder)
        default:
            break
        }

        guard let builder = try? await EmptyChatTab.restore(
            from: data.data, externalDependency: ()
        ) else {
            return nil
        }
        return createTab(for: builder)
    }
    #endif
}

