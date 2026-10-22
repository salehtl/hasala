import HasalaModels

extension AppModel {
  var projectsInProfile: Bool { router.sheet == .profile }

  func openProject(_ id: ProjectID) {
    if projectsInProfile { router.profile.append(.project(id)) } else { router.projectsPath.append(.project(id)) }
  }

  func editProject(_ id: ProjectID?) {
    if projectsInProfile { router.profile.append(.editProject(id)) } else { router.open(.project(id)) }
  }

  func newProject(_ starter: ProjectStarter) {
    if projectsInProfile { router.profile.append(.newProject(starter)) } else { router.open(.newProject(starter)) }
  }

  func addToProject(_ id: ProjectID) {
    if projectsInProfile { router.profile.append(.addToProject(id)) } else { router.projectsPath.append(.addToProject(id)) }
  }

  func leaveProject(_ id: ProjectID) {
    if projectsInProfile {
      while let last = router.profile.last, last == .project(id) || last == .addToProject(id) || last == .editProject(id) {
        router.profile.removeLast()
      }
    } else {
      while let last = router.projectsPath.last, last == .project(id) || last == .addToProject(id) {
        router.projectsPath.removeLast()
      }
    }
  }

  func projectRemovedFromEditor(_ id: ProjectID) {
    if !projectsInProfile { router.sheet = nil }
    leaveProject(id)
  }

  func projectSaved(_ id: ProjectID, created: Bool) {
    if projectsInProfile {
      if let last = router.profile.last, last == .editProject(created ? nil : id) || (created && Self.isStarter(last)) {
        router.profile.removeLast()
      }
      if created { router.profile.append(.project(id)) }
    } else {
      router.sheet = nil
      if created { router.projectsPath.append(.project(id)) }
    }
  }

  private static func isStarter(_ route: ProfileRoute) -> Bool {
    if case .newProject = route { return true }
    return false
  }

  func openProjectsTab(_ project: ProjectID? = nil) {
    router.tab = router.projectsTab
    if BuildSurface.showsPlanTab {
      router.plan = project.map { [.project($0)] } ?? [.projects]
    } else {
      router.projects = project.map { [.project($0)] } ?? []
    }
  }

  func openPlan(category: CategoryID? = nil) {
    let pushed = category.map { [$0] } ?? []
    if BuildSurface.showsPlanTab {
      router.tab = .plan
      router.plan = pushed.map { .category($0) }
    } else {
      router.open(.profile, profile: [.plan] + pushed.map { .category($0) })
    }
  }

  var planInProfile: Bool { projectsInProfile }

  func pushPlanCategory(_ id: CategoryID) {
    if planInProfile { router.profile.append(.category(id)) } else { router.plan.append(.category(id)) }
  }

  func pushPlanProject(_ id: ProjectID) {
    if planInProfile { router.profile.append(.project(id)) } else { router.plan.append(.project(id)) }
  }

  func pushPlanProjects() {
    if planInProfile { router.profile.append(.projects) } else { router.plan.append(.projects) }
  }

  func openPlanSheet(_ route: SheetRoute) {
    if planInProfile { router.overProfile = route } else { router.open(route) }
  }

  func closePlanSheet() {
    if router.overProfile != nil { router.overProfile = nil } else { router.sheet = nil }
  }
}
