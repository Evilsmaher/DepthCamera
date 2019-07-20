//
//  Extensions.swift
//  Camera
//
//  Created by Bradley French on 7/4/19.
//  Copyright © 2019 Bradley French. All rights reserved.
//

import UIKit

extension UIView {
    
    @IBInspectable
    var cornerRadius: CGFloat {
        get {
            return layer.cornerRadius
        }
        set {
            layer.cornerRadius = newValue
        }
    }
    
    @IBInspectable
    var isCircle: Bool {
        get {
            return layer.cornerRadius == self.bounds.size.height/2
        }
        set {
            if(newValue) {
                layer.cornerRadius = self.bounds.size.height/2
            }
            else {
                layer.cornerRadius = self.layer.cornerRadius
            }
        }
    }
}

extension DispatchQueue {
    
    static func background(delay: Double = 0.0, background: (()->Void)? = nil, completion: (() -> Void)? = nil) {
        DispatchQueue.global(qos: .background).async {
            background?()
            if let completion = completion {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: {
                    completion()
                })
            }
        }
    }
    
}
