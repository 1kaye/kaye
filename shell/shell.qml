//@ pragma UseQApplication
import Quickshell
import "modules/background" as BackgroundModule
import "modules/intro" as IntroModule
import "modules/bar" as BarModule
import "modules/menu" as MenuModule
import "modules/notifications" as NotificationModule
import "modules/osd" as OsdModule
import "modules/lock" as LockModule

// Kaye OS Single-Process Desktop Shell
ShellRoot {
  BackgroundModule.Background {}
  BarModule.Bar {}
  MenuModule.Menu {}
  NotificationModule.Notifications {}
  OsdModule.Osd {}
  LockModule.LockScreen {}
  IntroModule.StartupIntro {}
}
