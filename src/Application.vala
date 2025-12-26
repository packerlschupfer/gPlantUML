namespace GPlantUML {
    public class Application : Adw.Application {
        public Application() {
            Object(
                application_id: APP_ID,
                flags: ApplicationFlags.HANDLES_OPEN
            );
        }

        construct {
            ActionEntry[] action_entries = {
                { "about", this.on_about_action },
                { "preferences", this.on_preferences_action },
                { "quit", this.quit }
            };
            this.add_action_entries(action_entries, this);
            this.set_accels_for_action("app.quit", {"<primary>q"});
            this.set_accels_for_action("app.preferences", {"<primary>comma"});
            this.set_accels_for_action("win.new-tab", {"<primary>n"});
            this.set_accels_for_action("win.open", {"<primary>o"});
            this.set_accels_for_action("win.save", {"<primary>s"});
            this.set_accels_for_action("win.close-tab", {"<primary>w"});
        }

        protected override void activate() {
            base.activate();
            var win = this.active_window ?? new MainWindow(this);
            win.present();
        }

        protected override void open(File[] files, string hint) {
            base.open(files, hint);
            var win = this.active_window as MainWindow ?? new MainWindow(this);
            foreach (var file in files) {
                win.open_file(file);
            }
            win.present();
        }

        private void on_about_action() {
            var about = new Adw.AboutDialog() {
                application_name = APP_NAME,
                application_icon = APP_ID,
                developer_name = "gPlantUML Contributors",
                version = VERSION,
                developers = { "gPlantUML Contributors" },
                copyright = "© 2024 gPlantUML Contributors",
                license_type = Gtk.License.GPL_3_0
            };
            about.present(this.active_window);
        }

        private void on_preferences_action() {
            var prefs = new PreferencesDialog();
            prefs.present(this.active_window);
        }
    }
}
