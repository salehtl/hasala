import HasalaModels

extension AppModel {
  func openProject(_ id: ProjectID) {
    if showingProfile { router.profile.append(.project(id)) } else { router.projectsPath.append(.project(id)) }
  }

  func editProject(_ id: ProjectID?) {
    if showingProfile { router.profile.append(.editProject(id)) } else { router.open(.project(id)) }
  }

  func newProject(_ starter: ProjectStarter) {
    if showingProfile { router.profile.append(.newProject(starter)) } else { router.open(.newProject(starter)) }
  }

  func addToProject(_ id: ProjectID) {
    if showingProfile { router.profile.append(.addToProject(id)) } else { router.projectsPath.append(.addToProject(id)) }
  }

  func leaveAddToProject(_ id: ProjectID) {
    if showingProfile {
      if router.profile.last == .addToProject(id) { router.profile.removeLast() }
    } else if router.projectsPath.last == .addToProject(id) {
      router.projectsPath.removeLast()
    }
  }

  func leaveProject(_ id: ProjectID) {
    if showingProfile {
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
    if !showingProfile { router.sheet = nil }
    leaveProject(id)
  }

  func closeProjectEditor(_ project: ProjectID?) {
    if showingProfile, editorOnTop(project) { router.profile.removeLast() } else { router.sheet = nil }
  }

  func projectSaved(_ id: ProjectID, created: Bool) {
    if showingProfile {
      if editorOnTop(created ? nil : id) { router.profile.removeLast() }
      if created { router.profile.append(.project(id)) }
    } else {
      router.sheet = nil
      if created { router.projectsPath.append(.project(id)) }
    }
  }

  private func editorOnTop(_ project: ProjectID?) -> Bool {
    guard let last = router.profile.last else { return false }
    if last == .editProject(project) { return true }
    if project == nil, case .newProject = last { return true }
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

  func pushPlanCategory(_ id: CategoryID) {
    if showingProfile { router.profile.append(.category(id)) } else { router.plan.append(.category(id)) }
  }

  func pushPlanProject(_ id: ProjectID) {
    if showingProfile { router.profile.append(.project(id)) } else { router.plan.append(.project(id)) }
  }

  func pushPlanProjects() {
    if showingProfile { router.profile.append(.projects) } else { router.plan.append(.projects) }
  }

  func openPlanSheet(_ route: SheetRoute) {
    if showingProfile { router.overProfile = route } else { router.open(route) }
  }

  func closePlanSheet() {
    if router.overProfile != nil { router.overProfile = nil } else { router.sheet = nil }
  }
}
