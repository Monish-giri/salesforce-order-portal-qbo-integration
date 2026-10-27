import { LightningElement, wire } from 'lwc';
import USER_ID from '@salesforce/user/Id';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import USER_NAME from '@salesforce/schema/User.Name';
import USER_TYPE from '@salesforce/schema/User.UserType';

const USER_FIELDS = [USER_NAME, USER_TYPE];

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

    get isPartner() {
        return getFieldValue(this.userRecord?.data, USER_TYPE) === 'PowerPartner';
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

    get isBulkOrder() {
        return this.activeSection === 'bulkOrder'
            && this.isPartner
            && !this.showCart
            && !this.showCheckout
            && !this.isOrderConfirmation;
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
        return !this.isCatalog
            && !this.isBulkOrder
            && !this.isCart
            && !this.isCheckout
            && !this.isOrderConfirmation
            && !this.isOrders
            && !this.isReturns;
    }

    get sectionTitle() {
        const titles = {
            orders: 'My Orders',
            returns: 'Returns',
            bulkOrder: 'Bulk Order'
        };
        return titles[this.activeSection] || 'Portal';
    }

    get catalogNavClass() {
        return this.navClass('catalog');
    }

    get bulkOrderNavClass() {
        return this.navClass('bulkOrder');
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

    handleCartQuantityChange(event) {
        const product = event.detail;
        const quantity = Number(product.quantity);

        if (!Number.isInteger(quantity) || quantity < 0) {
            return;
        }

        const existing = this.cartItems.find(
            item => item.pricebookEntryId === product.pricebookEntryId
        );

        if (quantity === 0) {
            this.cartItems = this.cartItems.filter(
                item => item.pricebookEntryId !== product.pricebookEntryId
            );
            return;
        }

        if (existing) {
            this.cartItems = this.cartItems.map(item =>
                item.pricebookEntryId === product.pricebookEntryId
                    ? {
                        ...item,
                        quantity,
                        lineTotal: item.unitPrice * quantity
                    }
                    : item
            );
            return;
        }

        this.cartItems = [
            ...this.cartItems,
            {
                productId: product.productId,
                pricebookEntryId: product.pricebookEntryId,
                name: product.name,
                unitPrice: product.unitPrice,
                recommendedRetailPrice: product.recommendedRetailPrice,
                estimatedMarginAmount: product.estimatedMarginAmount,
                estimatedMarginPercent: product.estimatedMarginPercent,
                quantity,
                lineTotal: product.unitPrice * quantity
            }
        ];
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
