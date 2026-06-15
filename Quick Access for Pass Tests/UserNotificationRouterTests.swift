import Testing
import Foundation
import UserNotifications
@testable import Quick_Access_for_Pass

@MainActor
private final class FakeNotificationHandler: UserNotificationActionHandling {
    var received: [NotificationActionContext] = []
    var result = true

    func handleNotificationAction(_ context: NotificationActionContext) async -> Bool {
        received.append(context)
        return result
    }
}

@MainActor
private final class FakeCategoryRegistrar: UserNotificationCategoryRegistering {
    var categorySets: [Set<String>] = []

    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {
        categorySets.append(Set(categories.map(\.identifier)))
    }
}

@MainActor
struct UserNotificationRouterTests {
    @Test func dispatchesTypedContextToRegisteredHandler() async {
        let registrar = FakeCategoryRegistrar()
        let router = UserNotificationRouter(categoryRegistrar: registrar, assignAsDelegate: false)
        let handler = FakeNotificationHandler()
        router.register(handler, forCategoryIdentifier: "PASS_CLI_LOGIN")

        let handled = await router.dispatch(
            categoryIdentifier: "PASS_CLI_LOGIN",
            actionIdentifier: "LOGIN",
            rawUserInfo: ["host": "github.com", "keyNames": ["Work key"]],
            requestIdentifier: "request-1"
        )

        #expect(handled == true)
        #expect(handler.received.count == 1)
        #expect(handler.received.first?.actionIdentifier == "LOGIN")
        #expect(handler.received.first?.requestIdentifier == "request-1")
        #expect(handler.received.first?.userInfo.host == "github.com")
        #expect(handler.received.first?.userInfo.keyNames == ["Work key"])
    }

    @Test func returnsFalseWhenNoHandlerIsRegistered() async {
        let router = UserNotificationRouter(categoryRegistrar: FakeCategoryRegistrar(), assignAsDelegate: false)

        let handled = await router.dispatch(
            categoryIdentifier: "MISSING",
            actionIdentifier: "LOGIN",
            rawUserInfo: [:],
            requestIdentifier: "request-2"
        )

        #expect(handled == false)
    }

    @Test func mergesNotificationCategoriesWithoutDroppingExistingOnes() {
        let registrar = FakeCategoryRegistrar()
        let router = UserNotificationRouter(categoryRegistrar: registrar, assignAsDelegate: false)
        let ssh = UNNotificationCategory(identifier: "SSH_BATCH_MODE", actions: [], intentIdentifiers: [])
        let login = UNNotificationCategory(identifier: "PASS_CLI_LOGIN", actions: [], intentIdentifiers: [])

        router.registerCategory(ssh)
        router.registerCategory(login)

        #expect(registrar.categorySets.last == ["SSH_BATCH_MODE", "PASS_CLI_LOGIN"])
    }
}
