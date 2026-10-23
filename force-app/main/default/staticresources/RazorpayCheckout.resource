/*
 * Razorpay Standard Checkout loader.
 *
 * This static resource intentionally loads Razorpay's official Checkout.js
 * from Razorpay's CDN rather than copying a third-party/bundled SDK into
 * the repository.
 */
(function () {
    if (window.Razorpay) {
        window.RazorpayCheckoutReady = Promise.resolve(window.Razorpay);
        return;
    }

    if (window.RazorpayCheckoutReady) {
        return;
    }

    window.RazorpayCheckoutReady = new Promise(function (resolve, reject) {
        var existing = document.querySelector('script[data-razorpay-checkout="true"]');
        if (existing) {
            existing.addEventListener('load', function () {
                resolve(window.Razorpay);
            });
            existing.addEventListener('error', function () {
                reject(new Error('Unable to load Razorpay Checkout.'));
            });
            return;
        }

        var script = document.createElement('script');
        script.src = 'https://checkout.razorpay.com/v1/checkout.js';
        script.async = true;
        script.dataset.razorpayCheckout = 'true';
        script.onload = function () {
            if (window.Razorpay) {
                resolve(window.Razorpay);
            } else {
                reject(new Error('Razorpay Checkout loaded without exposing the Razorpay SDK.'));
            }
        };
        script.onerror = function () {
            reject(new Error('Unable to load Razorpay Checkout.'));
        };
        document.head.appendChild(script);
    });
})();
