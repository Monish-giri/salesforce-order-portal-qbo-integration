import { LightningElement, wire } from 'lwc';
import USER_ID from '@salesforce/user/Id';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import USER_NAME from '@salesforce/schema/User.Name';

const USER_FIELDS = [USER_NAME];

export default class OrderPortal extends LightningElement {
    activeSection = 'catalog';
    cartItems = [];
    showCart = false;
    showCheckout = false;
    orderConfirmation;

    @wire(getRecord, { recordId: USER_ID, fields: USER_FIELDS })
    userRecord;

    get userName() {
        return getFieldValue(this.userRecord?.data, USER_NAME) || 'Portal User';
    }

    get cartCount() {
        return this.cartItems.reduce((total, item) => total + item.quantity, 0);
    }

    get cartSubtotal() {
        return this.cartItems.reduce(
            (total, item) => total + (item.unitPrice * item.quantity),
            0
        );
    }

    get hasCartItems() {
        return this.cartItems.length > 0;
    }

    get isCatalog() {
        return this.activeSection === 'catalog' && !this.showCart;
    }

    get isCart() {
        return this.showCart && !this.showCheckout;
    }

    get isCheckout() {
        return this.showCheckout;
    }

    get isOrderConfirmation() {
        return !!this.orderConfirmation;
    }

    get isOrders() {
        return this.activeSection === 'orders' && !this.showCart && !this.showCheckout && !this.isOrderConfirmation;
    }

    get isReturns() {
        return this.activeSection === 'returns' && !this.showCart && !this.showCheckout && !this.isOrderConfirmation;
    }

    get isComingSoon() {
        return !this.isCatalog && !this.isCart && !this.isCheckout && !this.isOrderConfirmation && !this.isOrders && !this.isReturns;
    }

    get sectionTitle() {
        const titles = {
            orders: 'My Orders',
            returns: 'Returns'
        };
        return titles[this.activeSection] || 'Portal';
    }

    get catalogNavClass() {
        return this.navClass('catalog');
    }

    get ordersNavClass() {
        return this.navClass('orders');
    }

    get returnsNavClass() {
        return this.navClass('returns');
    }

    navClass(section) {
        return 'nav-item ' + (this.activeSection === section && !this.showCart ? 'active' : '');
    }

    handleNavigation(event) {
        const section = event.currentTarget.dataset.section;
        this.showCart = false;
        this.showCheckout = false;
        this.orderConfirmation = undefined;
        this.activeSection = section;
    }

    openCart() {
        this.orderConfirmation = undefined;
        this.showCheckout = false;
        this.showCart = true;
    }

    showCatalog() {
        this.orderConfirmation = undefined;
        this.showCheckout = false;
        this.showCart = false;
        this.activeSection = 'catalog';
    }

    openCheckout() {
        if (!this.hasCartItems) {
            return;
        }

        this.showCheckout = true;
        this.showCart = true;
    }

    handleCheckoutBack() {
        this.showCheckout = false;
        this.showCart = true;
    }

    handleOrderSubmitted(event) {
        this.orderConfirmation = event.detail;
        this.cartItems = [];
        this.showCheckout = false;
        this.showCart = false;
        this.activeSection = 'catalog';
    }

    handleAddToCart(event) {
        const product = event.detail;
        const existing = this.cartItems.find(
            item => item.pricebookEntryId === product.pricebookEntryId
        );

        if (existing) {
            this.cartItems = this.cartItems.map(item =>
                item.pricebookEntryId === product.pricebookEntryId
                    ? { ...item, quantity: item.quantity + product.quantity, lineTotal: item.unitPrice * (item.quantity + product.quantity) }
                    : item
            );
        } else {
            this.cartItems = [
                ...this.cartItems,
                { ...product, quantity: product.quantity, lineTotal: product.unitPrice * product.quantity }
            ];
        }
    }

    increaseQuantity(event) {
        const id = event.currentTarget.dataset.id;
        this.cartItems = this.cartItems.map(item =>
            item.pricebookEntryId === id
                ? {
                    ...item,
                    quantity: item.quantity + 1,
                    lineTotal: item.unitPrice * (item.quantity + 1)
                }
                : item
        );
    }

    decreaseQuantity(event) {
        const id = event.currentTarget.dataset.id;
        this.cartItems = this.cartItems
            .map(item =>
                item.pricebookEntryId === id
                    ? {
                        ...item,
                        quantity: item.quantity - 1,
                        lineTotal: item.unitPrice * (item.quantity - 1)
                    }
                    : item
            )
            .filter(item => item.quantity > 0);
    }

    removeItem(event) {
        const id = event.currentTarget.dataset.id;
        this.cartItems = this.cartItems.filter(
            item => item.pricebookEntryId !== id
        );
    }
}
