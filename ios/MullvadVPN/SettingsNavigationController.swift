//
//  SettingsNavigationController.swift
//  MullvadVPN
//
//  Created by pronebird on 02/07/2020.
//  Copyright © 2020 Mullvad VPN AB. All rights reserved.
//

import Foundation
import UIKit

class SettingsNavigationController: UINavigationController {
    override func viewDidLoad() {
        super.viewDidLoad()

        // Update account expiry
        Account.shared.updateAccountExpiry()
    }
}
