//! A value on the main thread that tells subscribers when it changes, the way Observation drives
//! the macOS app.

use std::cell::RefCell;
use std::rc::Rc;

pub struct Observable<T> {
    value: RefCell<T>,
    listeners: RefCell<Vec<Rc<dyn Fn(&T)>>>,
}

impl<T: Clone + PartialEq + 'static> Observable<T> {
    pub fn new(value: T) -> Rc<Self> {
        Rc::new(Self { value: RefCell::new(value), listeners: RefCell::default() })
    }

    pub fn get(&self) -> T {
        self.value.borrow().clone()
    }

    /// Notifies subscribers only when the value changes.
    pub fn set(&self, value: T) {
        if *self.value.borrow() == value {
            return;
        }
        *self.value.borrow_mut() = value;
        let value = self.get();
        // A copy, so a listener may subscribe or set again.
        let listeners = self.listeners.borrow().clone();
        for listener in listeners {
            listener(&value);
        }
    }

    pub fn update(&self, change: impl FnOnce(&mut T)) {
        let mut value = self.get();
        change(&mut value);
        self.set(value);
    }

    /// Calls `listener` with every later value. It lives as long as the observable.
    pub fn subscribe(&self, listener: impl Fn(&T) + 'static) {
        self.listeners.borrow_mut().push(Rc::new(listener));
    }

    /// Calls `listener` now and with every later value.
    pub fn watch(&self, listener: impl Fn(&T) + 'static) {
        listener(&self.get());
        self.subscribe(listener);
    }
}
