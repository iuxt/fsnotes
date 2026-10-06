// File format settings; note names are provided when creating a note.
import UIKit

class DefaultExtensionViewController: UITableViewController {
    private let extensions = ["markdown", "md", "txt"]

    override func viewDidLoad() {
        super.viewDidLoad()
        title = NSLocalizedString("Files", comment: "Settings")
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        extensions.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        NSLocalizedString("Extension", comment: "Settings")
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell()
        let ext = extensions[indexPath.row]
        cell.textLabel?.text = ext
        cell.accessoryType = UserDefaultsManagement.noteExtension == ext ? .checkmark : .none
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let ext = extensions[indexPath.row]
        UserDefaultsManagement.noteExtension = ext
        UserDefaultsManagement.fileFormat = NoteType.withExt(rawValue: ext)
        tableView.reloadData()
    }
}
