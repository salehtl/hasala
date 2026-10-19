import HasalaModels

extension AppModel {
  var projectsInProfile: Bool { router.sheet == .profile }

  func openProject(_ id: ProjectID) {
    if projectsInProfile { router.profile.append(.project(id)) } else { router.plan.append(.project(id)) }
  }

  func editProject(_ id: ProjectID?) {
    if projectsInProfile { router.profile.append(.editProject(id)) } else { router.open(.project(id)) }
  }

  func addToProject(_ id: ProjectID) {
    if projectsInProfile { router.profile.append(.addToProject(id)) } else { router.plan.append(.addToProject(id)) }
  }

  func leaveProject(_ id: ProjectID) {
    if projectsInProfile {
      while let last = router.profile.last, last == .project(id) || last == .addToProject(id) { router.profile.removeLast() }
    } else {
      while let last = router.plan.last, last == .project(id) || last == .addToProject(id) { router.plan.removeLast() }
    }
  }

  func projectSaved(_ id: ProjectID, created: Bool) {
    if projectsInProfile {
      if router.profile.last == .editProject(created ? nil : id) { router.profile.removeLast() }
      if created { router.profile.append(.project(id)) }
    } else {
      router.sheet = nil
      if created { router.plan.append(.project(id)) }
    }
  }
}
