// Copyright 2018-2019 Yubico AB
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import UIKit

class AboutViewController: UIViewController {

    // MARK: Outlets
    
    @IBOutlet var frameworkVersionLabel: UILabel!
    @IBOutlet var appVersionLabel: UILabel!
    
    // MARK: View lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        let appBundle = Bundle(for: AboutViewController.self)
        
        let libraryVersion = "2.0.1"
        let appVersion = appBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")!
        
        frameworkVersionLabel.text = "Library version: \(libraryVersion)"
        appVersionLabel.text = "Application version: \(appVersion)"
    }
}
