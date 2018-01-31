# Responsible for ensuring that any updates to a Standing Order are propagated to any
# orders belonging to that Standing Order which have been instantiated

class StandingOrderUpdater
  attr_reader :order_update_issues

  def initialize(standing_order)
    @standing_order = standing_order
    @order_update_issues = OrderUpdateIssues.new
  end

  def update!
    future_and_undated_orders.all? do |order|
      order.assign_attributes(customer_id: customer_id, email: customer.andand.email, distributor_id: shop_id)

      update_bill_address_for(order) if (bill_address.changes.keys & relevant_address_attrs).any?
      update_ship_address_for(order) if (ship_address.changes.keys & relevant_address_attrs).any?
      update_shipment_for(order) if shipping_method_id_changed?
      update_payment_for(order) if payment_method_id_changed?

      changed_standing_line_items.each do |sli|
        line_item = order.line_items.find_by_variant_id(sli.variant_id)
        if line_item.quantity == sli.quantity_was
          line_item.update_attributes(quantity: sli.quantity, skip_stock_check: true)
        else
          unless line_item.quantity == sli.quantity
            product_name = "#{line_item.product.name} - #{line_item.full_name}"
            order_update_issues.add(order, product_name)
          end
        end
      end

      new_standing_line_items.each do |sli|
        order.line_items.create(variant_id: sli.variant_id, quantity: sli.quantity, skip_stock_check: true)
      end

      order.line_items.where(variant_id: standing_line_items.select(&:marked_for_destruction?).map(&:variant_id)).destroy_all

      order.save
    end
  end

  private

  attr_reader :standing_order

  delegate :orders, :bill_address, :ship_address, :standing_line_items, to: :standing_order
  delegate :shop_id, :customer, :customer_id, to: :standing_order
  delegate :shipping_method, :shipping_method_id, :payment_method, :payment_method_id, to: :standing_order
  delegate :shipping_method_id_changed?, :shipping_method_id_was, to: :standing_order
  delegate :payment_method_id_changed?, :payment_method_id_was, to: :standing_order

  def future_and_undated_orders
    return @future_and_undated_orders unless @future_and_undated_orders.nil?
    @future_and_undated_orders = orders.joins(:order_cycle).merge(OrderCycle.not_closed).readonly(false)
  end

  def update_bill_address_for(order)
    unless addresses_match?(order.bill_address, bill_address)
      return order_update_issues.add(order, I18n.t('bill_address'))
    end
    order.bill_address.update_attributes(bill_address.attributes.slice(*relevant_address_attrs))
  end

  def update_ship_address_for(order)
    force_update = force_ship_address_update_for?(order)
    return unless force_update || order.shipping_method.require_ship_address?
    unless force_update || addresses_match?(order.ship_address, ship_address)
      return order_update_issues.add(order, I18n.t('ship_address'))
    end
    order.ship_address.update_attributes(ship_address.attributes.slice(*relevant_address_attrs))
  end

  def update_payment_for(order)
    payment = order.payments.with_state('checkout').where(payment_method_id: payment_method_id_was).last
    if payment
      payment.andand.void_transaction!
      order.payments.create(payment_method_id: payment_method_id, amount: order.reload.total)
    else
      unless order.payments.with_state('checkout').where(payment_method_id: payment_method_id).any?
        order_update_issues.add(order, I18n.t('admin.payment_method'))
      end
    end
  end

  def update_shipment_for(order)
    shipment = order.shipments.with_state('pending').where(shipping_method_id: shipping_method_id_was).last
    if shipment
      shipment.update_attributes(shipping_method_id: shipping_method_id)
      order.update_attribute(:shipping_method_id, shipping_method_id)
    else
      unless order.shipments.with_state('pending').where(shipping_method_id: shipping_method_id).any?
        order_update_issues.add(order, I18n.t('admin.shipping_method'))
      end
    end
  end

  def changed_standing_line_items
    standing_line_items.select{ |sli| sli.changed? && sli.persisted? }
  end

  def new_standing_line_items
    standing_line_items.select(&:new_record?)
  end

  def relevant_address_attrs
    ["firstname", "lastname", "address1", "zipcode", "city", "state_id", "country_id", "phone"]
  end

  def addresses_match?(order_address, standing_order_address)
    relevant_address_attrs.all? do |attr|
      order_address[attr] == standing_order_address.send("#{attr}_was") ||
        order_address[attr] == standing_order_address[attr]
    end
  end

  def force_ship_address_update_for?(order)
    return false unless shipping_method.require_ship_address?
    distributor_address = order.send(:address_from_distributor)
    relevant_address_attrs.all? do |attr|
      order.ship_address[attr] == distributor_address[attr]
    end
  end
end
