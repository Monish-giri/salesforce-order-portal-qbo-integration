import { LightningElement, api } from 'lwc';
import { loadScript } from 'lightning/platformResourceLoader';
import razorpayCheckout from '@salesforce/resourceUrl/RazorpayCheckout';
import getCheckoutContext from '@salesforce/apex/OrderSubmissionService.getCheckoutContext';
import submitOrder from '@salesforce/apex/OrderSubmissionService.submitOrder';
import createPaymentOrder from '@salesforce/apex/RazorpayPaymentService.createPaymentOrder';
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
    selectedPaymentMethod = 'Online';
    submittedOrder;
    razorpayPaymentOrder;
    razorpayLoaded = false;

    connectedCallback() {
        this.loadCheckoutContext();
    }

    get isPartner() { return this.context?.isPartner === true; }
    get isCustomer() { return this.context?.isPartner === false; }

    get customerOptions() {
        return (this.context?.customerAccounts ?? []).map((account) => ({ label: account.name, value: account.id }));
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
        const selected = (this.context?.customerAccounts ?? []).find(account => account.id === this.selectedAccountId);
        return selected?.name || this.context?.defaultOrderAccountName || 'Customer account';
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

    handleAccountChange(event) { this.selectedAccountId = event.detail.value; }
    handlePaymentMethodChange(event) {
        this.selectedPaymentMethod = event.detail.value;
        this.submittedOrder = undefined;
        this.razorpayPaymentOrder = undefined;
        this.errorMessage = undefined;
    }

    async handlePlaceOrder() {
        if (!this.cartItems.length || !this.selectedAccountId) {
            this.errorMessage = 'Select a customer account before placing the order.';
            return;
        }
        if (!this.selectedPaymentMethod) {
            this.errorMessage = 'Select a payment method before placing the order.';
            return;
        }

        this.isSubmitting = true;
        this.errorMessage = undefined;
        try {
            if (this.selectedPaymentMethod === 'Online') {
                if (!this.submittedOrder) {
                    this.submittedOrder = await this.createSalesforceOrder();
                }
                await this.startRazorpayPayment();
                return;
            }

            const result = await this.createSalesforceOrder();
            this.dispatchEvent(new CustomEvent('ordersubmitted', { detail: result }));
        } catch (error) {
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

    async startRazorpayPayment() {
        this.isPaymentProcessing = true;

        const paymentOrder = await createPaymentOrder({
            orderId: this.submittedOrder.orderId
        });
        this.razorpayPaymentOrder = paymentOrder;

        await this.ensureRazorpayLoaded();

        const checkoutOptions = {
            key: paymentOrder.keyId,
            amount: paymentOrder.amountPaise,
            currency: paymentOrder.currencyCode,
            name: 'Order Portal',
            description: `Payment for Order ${this.submittedOrder.orderNumber}`,
            order_id: paymentOrder.razorpayOrderId,
            notes: {
                receipt: paymentOrder.receipt,
                salesforceOrderId: this.submittedOrder.orderId,
                salesforceOrderNumber: this.submittedOrder.orderNumber
            },
            handler: (response) => this.handleRazorpaySuccess(response),
            modal: {
                ondismiss: () => {
                    this.isPaymentProcessing = false;
                    this.errorMessage = 'Payment was not completed. Your order is saved and you can try again.';
                }
            }
        };

        try {
            const Razorpay = window.Razorpay;
            if (typeof Razorpay !== 'function') {
                throw new Error('Razorpay Checkout is not available.');
            }

            const checkout = new Razorpay(checkoutOptions);
            checkout.open();
        } catch (error) {
            this.isPaymentProcessing = false;
            throw new Error(error?.message || 'Unable to open Razorpay Checkout.');
        }
    }

    async ensureRazorpayLoaded() {
        if (!this.razorpayLoaded) {
            await loadScript(this, razorpayCheckout);
            this.razorpayLoaded = true;
        }

        if (window.RazorpayCheckoutReady) {
            await window.RazorpayCheckoutReady;
        }

        if (typeof window.Razorpay !== 'function') {
            throw new Error('Unable to load Razorpay Checkout.');
        }
    }

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
