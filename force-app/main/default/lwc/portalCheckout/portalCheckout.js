import { LightningElement, api } from 'lwc';
import getCheckoutContext from '@salesforce/apex/OrderSubmissionService.getCheckoutContext';
import submitOrder from '@salesforce/apex/OrderSubmissionService.submitOrder';
import createPaymentOrder from '@salesforce/apex/RazorpayPaymentService.createPaymentOrder';
import getPaymentReadiness from '@salesforce/apex/RazorpayPaymentService.getPaymentReadiness';
import verifyPayment from '@salesforce/apex/RazorpayPaymentService.verifyPayment';
import getActiveSchedule from '@salesforce/apex/B2BEarlyPaymentDiscountService.getActiveSchedule';

export default class PortalCheckout extends LightningElement {
    @api cartItems = [];
    isLoading = true;
    isSubmitting = false;
    isPaymentProcessing = false;
    errorMessage;
    context;
    discountSchedule = [];
    selectedAccountId;
    selectedOrderScope = 'Self';
    selectedPaymentMethod = 'Online';
    submittedOrder;
    razorpayPaymentOrder;
    paymentWindow;

    connectedCallback() {
        this.loadCheckoutContext();
        window.addEventListener('message', this.handlePaymentMessage);
    }

    disconnectedCallback() {
        window.removeEventListener('message', this.handlePaymentMessage);
    }

    get isPartner() { return this.context?.isPartner === true; }
    get isCustomer() { return this.context?.isPartner === false; }

    get customerOptions() {
        return (this.context?.customerAccounts ?? []).map((account) => ({ label: account.name, value: account.id }));
    }

    get partnerOrderScopeOptions() {
        return [
            { label: 'For my business', value: 'Self' },
            { label: 'On behalf of a customer', value: 'Customer' }
        ];
    }

    get isOrderingForCustomer() {
        return this.isPartner && this.selectedOrderScope === 'Customer';
    }

    get noLinkedCustomers() {
        return this.isOrderingForCustomer && this.customerOptions.length === 0;
    }

    get paymentOptions() {
        if (this.isPartner) {
            return [
                { label: 'B2B Invoice / Credit Terms', value: 'Invoice' }
            ];
        }

        return [
            { label: 'Pay Online', value: 'Online' },
            { label: 'Cash on Delivery', value: 'Cash on Delivery' }
        ];
    }

    get paymentHeading() {
        return this.isPartner ? 'B2B payment terms' : 'Choose your payment method';
    }

    get orderAccountName() {
        if (this.isPartner && this.selectedOrderScope === 'Self') {
            return this.context?.actorAccountName || 'Partner account';
        }
        const selected = (this.context?.customerAccounts ?? []).find(account => account.id === this.selectedAccountId);
        return selected?.name || 'Select a customer account';
    }

    get itemCount() { return this.cartItems.reduce((total, item) => total + item.quantity, 0); }

    get cartSubtotal() {
        return this.cartItems.reduce((total, item) => total + (item.unitPrice * item.quantity), 0);
    }

    get b2bRecommendedRetailTotal() {
        if (!this.isPartner) return 0;
        return this.cartItems.reduce((total, item) => total + ((item.recommendedRetailPrice || 0) * item.quantity), 0);
    }

    get b2bEstimatedMarginTotal() {
        if (!this.isPartner) return 0;
        return this.cartItems.reduce((total, item) => total + ((item.estimatedMarginAmount || 0) * item.quantity), 0);
    }

    get b2bEstimatedMarginPercent() {
        if (!this.isPartner || !this.b2bRecommendedRetailTotal) return 0;
        return (this.b2bEstimatedMarginTotal / this.b2bRecommendedRetailTotal) * 100;
    }

    get hasB2BMarginData() { return this.isPartner && this.b2bRecommendedRetailTotal > 0; }

    get hasB2BDiscountSchedule() {
        return this.isPartner && this.discountSchedule.length > 0;
    }

    get paymentSummary() {
        if (this.isPartner) {
            return 'Your order will be invoiced with the configured B2B payment terms. Pay earlier to receive the highest available discount.';
        }
        if (this.selectedPaymentMethod === 'Cash on Delivery') return 'Pay the full order amount when your order is delivered.';
        if (this.isPaymentProcessing) return 'Opening secure Razorpay Checkout...';
        if (this.submittedOrder) return 'Your Salesforce order is ready. Complete the payment in Razorpay to finish checkout.';
        return 'Pay the full order amount securely online through Razorpay.';
    }

    get placeOrderLabel() {
        if (this.isSubmitting) return this.selectedPaymentMethod === 'Online' ? 'Preparing payment...' : 'Placing order...';
        if (this.submittedOrder && this.selectedPaymentMethod === 'Online') return 'Pay Now';
        return 'Place Order';
    }

    async loadCheckoutContext() {
        this.isLoading = true;
        this.errorMessage = undefined;
        try {
            this.context = await getCheckoutContext();
            this.selectedAccountId = this.context?.defaultOrderAccountId;
            this.selectedOrderScope = 'Self';
            this.selectedPaymentMethod = this.context?.isPartner ? 'Invoice' : 'Online';

            if (this.context?.isPartner) {
                await this.loadDiscountSchedule();
            }
        } catch (error) {
            this.errorMessage = this.reduceError(error);
        } finally {
            this.isLoading = false;
        }
    }

    async loadDiscountSchedule() {
        try {
            this.discountSchedule = await getActiveSchedule();
        } catch (error) {
            // The discount schedule is informational at checkout. Do not block order placement if it cannot load.
            this.discountSchedule = [];
        }
    }

    handleOrderScopeChange(event) {
        this.selectedOrderScope = event.detail.value;
        this.selectedAccountId = this.selectedOrderScope === 'Self'
            ? this.context?.actorAccountId
            : undefined;
        this.errorMessage = undefined;
    }

    handleAccountChange(event) {
        this.selectedAccountId = event.detail.value;
        this.errorMessage = undefined;
    }
    handlePaymentMethodChange(event) {
        this.selectedPaymentMethod = event.detail.value;
        this.submittedOrder = undefined;
        this.razorpayPaymentOrder = undefined;
        this.errorMessage = undefined;
    }

    async handlePlaceOrder() {
        // Once Salesforce has created the order, the parent clears the cart.
        // A payment retry must continue with submittedOrder rather than require cart items.
        if ((!this.cartItems.length && !this.submittedOrder) || !this.selectedAccountId) {
            this.errorMessage = this.isOrderingForCustomer
                ? 'Select the customer account you are ordering for.'
                : 'Select the account before placing the order.';
            return;
        }
        if (!this.selectedPaymentMethod) {
            this.errorMessage = 'Select a payment method before placing the order.';
            return;
        }

        this.isSubmitting = true;
        this.errorMessage = undefined;

        if (this.selectedPaymentMethod === 'Online') {
            // Open a blank window synchronously from the user click so browser popup blockers
            // do not prevent the later Razorpay checkout navigation after the Apex callout.
            this.paymentWindow = window.open(
                'about:blank',
                'razorpayCheckout',
                'width=500,height=760,resizable=yes,scrollbars=yes'
            );

            if (!this.paymentWindow) {
                this.isSubmitting = false;
                this.errorMessage = 'Your browser blocked the payment window. Please allow pop-ups for the Order Portal and try again.';
                return;
            }
        }

        try {
            if (this.selectedPaymentMethod === 'Online') {
                if (!this.submittedOrder) {
                    this.submittedOrder = await this.createSalesforceOrder();
                    // Clear the parent cart immediately after Salesforce confirms the order.
                    // Keep this checkout instance and submittedOrder for invoice/payment retries.
                    this.dispatchEvent(new CustomEvent('ordercreated', {
                        detail: this.submittedOrder
                    }));
                }
                await this.waitForInvoiceAndStartPayment();
                return;
            }

            const result = await this.createSalesforceOrder();
            this.dispatchEvent(new CustomEvent('ordersubmitted', { detail: result }));
        } catch (error) {
            if (this.paymentWindow && !this.paymentWindow.closed) {
                this.paymentWindow.close();
            }
            this.paymentWindow = undefined;
            this.errorMessage = this.reduceError(error);
        } finally {
            this.isSubmitting = false;
            this.isPaymentProcessing = false;
        }
    }

    async createSalesforceOrder() {
        return submitOrder({
            cartJson: JSON.stringify(this.cartItems.map(item => ({
                pricebookEntryId: item.pricebookEntryId,
                quantity: item.quantity
            }))),
            submissionKey: this.createSubmissionKey(),
            orderForAccountId: this.selectedAccountId,
            paymentMethod: this.selectedPaymentMethod
        });
    }

    async waitForInvoiceAndStartPayment() {
        this.isPaymentProcessing = true;

        // Invoice creation is asynchronous: submitOrder publishes Order_Invoice_Request__e
        // and the QuickBooks invoice can be created shortly afterwards. Poll readiness
        // rather than immediately failing the customer's checkout.
        const maxAttempts = 60;
        const intervalMs = 1000;

        for (let attempt = 0; attempt < maxAttempts; attempt += 1) {
            if (!this.paymentWindow || this.paymentWindow.closed) {
                throw new Error('The payment window was closed. Your order is saved and you can try again from My Orders.');
            }

            const readiness = await getPaymentReadiness({
                orderId: this.submittedOrder.orderId
            });

            if (readiness?.ready) {
                await this.startRazorpayPayment();
                return;
            }

            if (readiness?.message && !readiness.message.toLowerCase().includes('waiting')) {
                throw new Error(readiness.message);
            }

            await new Promise(resolve => window.setTimeout(resolve, intervalMs));
        }

        throw new Error('The QuickBooks invoice is taking longer than expected to become available. Your order is saved. Please open My Orders and try the payment again shortly.');
    }

    async startRazorpayPayment() {
        const paymentOrder = await createPaymentOrder({
            orderId: this.submittedOrder.orderId
        });
        this.razorpayPaymentOrder = paymentOrder;

        const checkoutUrl = this.buildRazorpayCheckoutUrl(paymentOrder);
        if (!this.paymentWindow || this.paymentWindow.closed) {
            throw new Error('Unable to open the Razorpay payment window. Please allow pop-ups and try again.');
        }

        this.paymentWindow.location.href = checkoutUrl;
        this.paymentWindow.focus();
    }

    buildRazorpayCheckoutUrl(paymentOrder) {
        const pathSegments = window.location.pathname.split('/').filter(Boolean);
        const sitePrefix = pathSegments[0];
        const visualforcePath = sitePrefix
            ? `/${sitePrefix}/apex/RazorpayCheckoutBridge`
            : '/apex/RazorpayCheckoutBridge';

        const params = new URLSearchParams({
            keyId: paymentOrder.keyId,
            amount: String(paymentOrder.amountPaise),
            currency: paymentOrder.currencyCode,
            orderId: paymentOrder.razorpayOrderId,
            receipt: paymentOrder.receipt,
            parentOrigin: window.location.origin
        });

        return `${window.location.origin}${visualforcePath}?${params.toString()}`;
    }

    handlePaymentMessage = (event) => {
        if (!this.paymentWindow || event.source !== this.paymentWindow) {
            return;
        }

        const message = event.data || {};
        if (!['razorpay-success', 'razorpay-error', 'razorpay-dismissed'].includes(message.type)) {
            return;
        }

        if (message.type === 'razorpay-success') {
            this.handleRazorpaySuccess({
                razorpay_payment_id: message.payload?.razorpayPaymentId,
                razorpay_order_id: message.payload?.razorpayOrderId,
                razorpay_signature: message.payload?.razorpaySignature
            });
            return;
        }

        this.isPaymentProcessing = false;
        this.isSubmitting = false;

        if (message.type === 'razorpay-dismissed') {
            this.errorMessage = 'Payment was not completed. Your order is saved and you can try again.';
        } else {
            this.errorMessage = message.payload?.message || 'Razorpay payment failed. Please try again.';
        }

        this.paymentWindow = undefined;
    };

    async handleRazorpaySuccess(response) {
        try {
            this.isPaymentProcessing = true;
            this.errorMessage = undefined;

            const verification = await verifyPayment({
                orderId: this.submittedOrder.orderId,
                razorpayPaymentId: response?.razorpay_payment_id,
                razorpayOrderId: response?.razorpay_order_id,
                razorpaySignature: response?.razorpay_signature
            });

            if (!verification?.success) {
                throw new Error('Razorpay payment could not be verified.');
            }

            this.dispatchEvent(new CustomEvent('ordersubmitted', {
                detail: {
                    ...this.submittedOrder,
                    payment: verification
                }
            }));
        } catch (error) {
            this.errorMessage = this.reduceError(error);
        } finally {
            this.isPaymentProcessing = false;
            this.isSubmitting = false;
            this.paymentWindow = undefined;
        }
    }

    handleBack() { this.dispatchEvent(new CustomEvent('backtocart')); }
    createSubmissionKey() { return `portal-${Date.now()}-${Math.random().toString(36).slice(2, 12)}`; }

    reduceError(error) {
        if (error?.body?.message) return error.body.message;
        if (Array.isArray(error?.body) && error.body.length > 0) return error.body.map(item => item.message).join(', ');
        return error?.message || 'An unexpected error occurred while processing the order.';
    }
}
