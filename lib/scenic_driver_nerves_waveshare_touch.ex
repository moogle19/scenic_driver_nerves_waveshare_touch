#
#  Created by Boyd Multerer on June 18, 2018.
#  Copyright © 2018 Kry10 Industries. All rights reserved.
#
#  track messages from a multi-touch driver, translate them, and send up to the viewport
#
defmodule Scenic.Driver.Nerves.WaveshareTouch do
  @moduledoc """
  # scenic_driver_nerves_waveshare_touch

  The main driver for receiving touch input on Nerves devices.

  So far only tested on Raspberry Pi 3 devices. In other words, it is still early
  days for this driver. There will probably be changes in the future. Especially
  regarding multi-touch.

  For now, the events coming to a scene via the touch driver look like the
  same cursor oriented events that come from glfw with a mouse.

  ## Installation

  In your Nerves applications dependencies include the following line

      ...
      {:scenic_driver_nerves_waveshare_touch, , "~> 0.1"}
      ...

  You do not need to include it in the "host" mix target deps. There you should be
  using the glfw driver and that will take care of the touch input for you.

  ## Configuration

  Configure the touch driver the same way you configure other drivers. Add it
  to the driver list in your ViewPort's config.exs file.

      config :sample, :viewport, %{
            size: {1024, 600},
            default_scene: {Sample.Scene.Simple, nil},
            drivers: [
              %{
                module: Scenic.Driver.Nerves.Rpi,
              },
              %{
                module: Scenic.Driver.Nerves.WaveshareTouch,
                opts: [
                  device: "WaveShare WaveShare Touchscreen",
                  calibration: {{1,0,0},{1,0,0}}
                ],
              }
            ]
          }

  ## Device Name

  __This is important__

  You need to supply the name of the OS driver you are getting the touch information from.
  You don't need to supply the entire string, but what you supply must be in the
  actual device name.

  When you use the sample scene set up by scenic.new.nerves, it will display the
  available device names. Otherwise, use the hex package [input_event](https://hex.pm/packages/input_event) to enumerate them.

  Note that some drivers take a short time to come online. (I'm looking at you FT5406).
  Don't be surprised if touch doesn't work for a second or two after the rest of the
  UI starts to work. Other drivers initialize themselves faster.

  The device name is this part of the configuration

      device: "FT5406 memory based driver",

  ## Calibration

  Calibration maps the resolution/coordinates of the touch screen to the
  coordinates and scale of the display. On the official Raspberry Pi
  7" touch screen, then are the same, so the mapping is easy (1.0).

  However, with other displays (I have a Dell touchscreen I've tested with),
  that is not the case and you need to provide a proper mapping. The values
  are sufficient to support some rotation and out-of-alignment issues in
  the future, but I haven't written a calibration scene yet to provide
  those values in an easy/automatic way.

  ## Calibration Data

  `{{ax, bx, dx}, {ay, by dy}}`

  When a location `{x, y}` comes in from the touch screen, it is projected
  by the calibration data via the formula

      final_x = x * ax + y * bx + dx
      final_y = x * ay + y * by + dy

  See [Calibration in touch-screen systems](http://www.ti.com/lit/an/slyt277/slyt277.pdf) for more information.

  If the touch panel is not rotate or otherwise out of alignment, then you can supply
  a simple calibration by providing scale factors for `ax` and `ay`.

  The calibration is this part of the configuration

      calibration: {{1,0,0},{0,1,0}}
  """

  use Scenic.ViewPort.Driver
  alias Scenic.ViewPort

  # alias :mnesia, as: Mnesia

  require Logger

  # import IEx

  # @port  '/scenic_driver_rpi_touch'

  @init_retry_ms 400

  # ============================================================================
  # client callable api

  @doc """
  Retrieve stats about the driver
  """
  def query_stats(pid), do: GenServer.call(pid, :query_stats)

  # ============================================================================
  # startup

  def init(viewport, {_, _} = screen_size, config) do
    device =
      case config[:device] do
        device when is_bitstring(device) ->
          Process.send(self(), {:init_driver, device}, [])
          device

        _ ->
          msg =
            "Scenic.Driver.Nerves.Touch requires a device option to start up\r\n" <>
              "The named device must reference a valid driver on your target system\r\n" <>
              "The following works with a raspberry pi with the standard 7 inch touch screen...\r\n" <>
              "%{\r\n" <>
              "  module: Scenic.Driver.Nerves.WaveshareTouch,\r\n" <>
              "  opts: [device: \"FT5406 memory based driver\"],\r\n" <> "}"

          Logger.error(msg)
          nil
      end

    calibration =
      case config[:calibration] do
        nil ->
          nil

        {
          {ax, bx, dx},
          {ay, by, dy}
        } = calib
        when is_number(ax) and is_number(bx) and is_number(dx) and is_number(ay) and is_number(by) and
               is_number(dy) ->
          calib

        _ ->
          msg =
            "Invalid touch calibration in driver config\r\n" <>
              "Must be a tuple in the form of {{ax, bx, dx}, {ay, by, dy}}\r\n" <>
              "See documentation for details"

          Logger.error(msg)
          nil
      end

    state = %{
      device: device,
      event_path: nil,
      event_pid: nil,
      viewport: viewport,
      slot: 0,
      touch: false,
      fingers: %{},
      # TODO: REMOVE
      finger_count: 0,
      mouse_x: nil,
      mouse_y: nil,
      mouse_event: nil,
      config: config,
      calibration: calibration,
      screen_size: screen_size
    }

    {:ok, state}
  end

  # ============================================================================
  def handle_call(_msg, _from, state), do: {:reply, :e_no_impl, state}

  # ============================================================================

  # --------------------------------------------------------
  # We are starting up.
  # Enumerate the events/device pairs and look for the requested device.
  # If it is NOT found, log a warning and try again later (it might not be loaded yet)
  # If it is found, connect and start working for real
  def handle_info({:init_driver, requested_device}, state) do
    InputEvent.enumerate()
    |> Enum.find_value(fn
      # input_event 0.3.1
      {event, device_name} when is_binary(device_name) ->
        if device_name =~ requested_device do
          event
        else
          nil
        end

      # input_event >= 0.4.0
      {event, info} when is_map(info) ->
        if info.name =~ requested_device do
          event
        else
          nil
        end
    end)
    |> case do
      nil ->
        Logger.warn("Device not found: #{inspect(requested_device)}")
        # not found. Try again later
        Process.send_after(self(), {:init_driver, requested_device}, @init_retry_ms)
        {:noreply, state}

      event ->
        # start listening for input messages on the event file
        {:ok, pid} = InputEvent.start_link(event)

        # start post-init calibration check
        # Process.send(self(), :post_init, [])
        # Process.send(self(), {:post_init, 20}, [])

        {:noreply, %{state | event_pid: pid, event_path: event}}
    end
  end

  # --------------------------------------------------------
  # We have connected to the touch driver. See if there is a stored
  # calibration override
  # def handle_info( {:post_init, 0}, state ), do: {:noreply, state}
  # def handle_info( :post_init, %{
  # viewport:     vp,
  # config:       config,
  # calibration:  calibration,
  # screen_size: {width, height}
  # } = state ) do
  # if there ls a locally stored calibration record, use that instead of the
  # default one that was passed into config. Measured beats default

  # Find the static monitor. Try again later if there isn't one.
  #     {:ok, %{drivers: drivers}} = ViewPort.query_status(vp)
  #     state = Enum.find(drivers, fn
  #       {_pid, %{type: "Static Monitor"}} -> true
  #       _ -> false
  #     end)
  #     |> case do
  #       nil ->
  #         # not found. Try again later
  # IO.puts "try again later"
  #         Process.send_after(self(), {:post_init, tries_left - 1}, @init_retry_ms)
  #         state

  #       %{width: width, height: height} ->
  # pry()
  #         Mnesia.start()
  #         Mnesia.dirty_read({:touch_calibration, {width,height}})
  #         |> case do
  #           [] -> state
  #           [{:touch_calibration, _, {{_,_,_},{_,_,_}} = calib}] ->
  #             Map.put(state, :calibration, calib)
  #           _ ->
  #             # don't understand the stored calibration. Do nothing.
  #             state
  #         end

  #       _ ->
  #         # unknown monitor format. ignore it.
  #         state
  #     end

  # pry()
  #     Mnesia.start()
  #     state = Mnesia.dirty_read({:touch_calibration, {width,height}})
  #     |> case do
  #       [] -> state
  #       [{:touch_calibration, _, {{_,_,_},{_,_,_}} = calib}] ->
  #         Map.put(state, :calibration, calib)
  #       _ ->
  #         # don't understand the stored calibration. Do nothing.
  #         state
  #     end
  # pry()
  #   {:noreply, state}
  # end

  # --------------------------------------------------------

  # Ignore single abs misc events
  def handle_info(
        {:input_event, source, [{:ev_abs, :abs_misc, _}] = events},
        %{event_path: event_path} = state
      )
      when source == event_path do
    {:noreply, state}
  end

  # Multitouch event
  def handle_info(
        {:input_event, source, [{:ev_abs, :abs_misc, finger_number} | _] = events},
        %{event_path: event_path} = state
      )
      when source == event_path do
    # Logger.debug("Finger #{inspect(finger_number + 1)}: #{inspect(events)}")
    if finger_number + 1 > state.finger_count do
      Logger.debug("Fingers: #{state.finger_count + 1}")
      {:noreply, %{state | finger_count: state.finger_count + 1}}
    else
      {:noreply, state}
    end
  end

  # Touch start/end events
  def handle_info(
        {:input_event, source, [{:ev_msc, :msc_scan, _} | _] = events},
        %{event_path: event_path} = state
      )
      when source == event_path do
    if(Enum.member?(events, {:ev_key, :btn_touch, 0})) do
      if Enum.any?(events, fn {class, type, value} ->
           class == :ev_abs && type == :abs_misc && value < 5
         end) do
        # Logger.debug("Finger removed event: #{inspect(events)}")
        Logger.debug("Fingers: #{state.finger_count - 1}")
        {:noreply, %{state | finger_count: state.finger_count - 1}}
      else
        # Logger.debug("Touch UP event: #{inspect(events)}")
        Logger.debug("Fingers: #{state.finger_count - 1}")
        {:noreply, %{state | finger_count: state.finger_count - 1}}
      end
    else
      if Enum.any?(events, fn {class, type, value} ->
           class == :ev_abs && type == :abs_misc && value < 5
         end) do
        # Logger.debug("Touch DOWN AFTER UP event: #{inspect(events)}")
        {:noreply, state}
      else
        # Logger.debug("Touch DOWN event: #{inspect(events)}")
        Logger.debug("Fingers: 1")
        {:noreply, %{state | finger_count: 1}}
      end
    end
  end

  # Single finger events
  def handle_info({:input_event, source, events}, %{event_path: event_path} = state)
      when source == event_path do
    # Logger.info(inspect(inspect(events)))
    # Logger.debug("Finger 1: #{inspect(events)}")

    if [{:ev_abs, :abs_misc, value}] =
         Enum.reverse(events)
         |> Enum.take(1) do
      if value <= 5 do
        # Logger.debug("Multitouch event (2): #{inspect(events)}")
        {:noreply, state}
      else
        state =
          Enum.reduce(events, state, fn ev, s ->
            ev_abs(ev, s)
            |> simulate_mouse(ev)
          end)
          |> send_mouse()

        {:noreply, state}
      end
    else
      state =
        Enum.reduce(events, state, fn ev, s ->
          ev_abs(ev, s)
          |> simulate_mouse(ev)
        end)
        |> send_mouse()

      {:noreply, state}
    end
  end

  # --------------------------------------------------------
  def handle_info(msg, state) do
    Logger.info("Unhandled info: #{inspect(msg)}")
    IO.puts("Unhandled info. msg: #{inspect(msg)}")
    {:noreply, state}
  end

  # ============================================================================
  defp ev_abs(event, state)

  # Event identifier
  defp ev_abs({:ev_msc, :msc_scan, id}, state) do
    fingers =
      state.fingers
      |> Map.put(id, %{id: id})

    state
    |> Map.put(:fingers, fingers)
    |> Map.put(:slot, id)
  end

  # x Position changed
  defp ev_abs(
         {:ev_abs, :abs_x, x},
         %{
           fingers: fingers,
           slot: slot
         } = state
       )
       when length(fingers) > 0 do
    fingers = put_in(fingers, [slot, :x], x)
    %{state | fingers: fingers}
  end

  # x Position changed
  defp ev_abs(
         {:ev_abs, :abs_y, y},
         %{
           fingers: fingers,
           slot: slot
         } = state
       )
       when length(fingers) > 0 do
    fingers = put_in(fingers, [slot, :y], y)
    %{state | fingers: fingers}
  end

  # defp ev_abs(
  #        {:ev_abs, :abs_pressure, pressure},
  #        %{
  #          fingers: fingers,
  #          slot: slot
  #        } = state
  #      ) do
  #   fingers = put_in(fingers, [slot, :pressure], pressure)
  #   %{state | fingers: fingers}
  # end

  # Touch began
  defp ev_abs(
         {:ev_key, :btn_touch, 1},
         %{
           slot: _slot
         } = state
       ) do
    %{state | touch: true}
  end

  # Touch ended
  defp ev_abs(
         {:ev_key, :btn_touch, 0},
         %{
           slot: slot
         } = state
       ) do
    state
    |> Map.put(:fingers, Map.delete(state.fingers, slot))
    |> Map.put(:touch, false)
  end

  # if other ev types need to be handled, add them here

  defp ev_abs(msg, state) do
    # Logger.info("unhandled: #{inspect(msg)}")
    # IO.puts "EV unhandled: #{inspect(msg)}"
    state
  end

  # ============================================================================
  # translate raw events into simulated mouse state

  defp simulate_mouse(state, ev)

  defp simulate_mouse(
         %{slot: slot} = state,
         {:ev_key, :btn_touch, 0}
       ) do
    %{state | mouse_event: :mouse_up}
  end

  defp simulate_mouse(
         %{slot: slot} = state,
         {:ev_key, :btn_touch, 1}
       ) do
    %{state | mouse_event: :mouse_down}
  end

  defp simulate_mouse(
         %{slot: slot, mouse_event: nil} = state,
         {:ev_abs, :abs_x, x}
       ) do
    %{state | mouse_event: :mouse_move, mouse_x: x}
  end

  defp simulate_mouse(
         %{slot: slot} = state,
         {:ev_abs, :abs_x, x}
       ) do
    %{state | mouse_x: x}
  end

  defp simulate_mouse(
         %{slot: slot, mouse_event: nil} = state,
         {:ev_abs, :abs_y, y}
       ) do
    %{state | mouse_event: :mouse_move, mouse_y: y}
  end

  defp simulate_mouse(
         %{slot: slot} = state,
         {:ev_abs, :abs_y, y}
       ) do
    %{state | mouse_y: y}
  end

  # ignore everything else
  defp simulate_mouse(state, _), do: state

  # ============================================================================
  # send simulated mouse events after handling a batch of raw events

  defp send_mouse(state)

  # send cursor_button press. no modifiers
  defp send_mouse(
         %{
           viewport: viewport,
           mouse_x: x,
           mouse_y: y,
           mouse_event: :mouse_down
         } = state
       )
       when is_number(x) and is_number(y) do
    # IO.puts "MOUSE press: #{inspect({x,y})}"
    pos = project_pos({x, y}, state)
    ViewPort.input(viewport, {:cursor_button, {:left, :press, 0, pos}})
    %{state | mouse_event: nil}
  end

  # send cursor_button release. no modifiers
  defp send_mouse(%{viewport: viewport, mouse_x: x, mouse_y: y, mouse_event: :mouse_up} = state)
       when is_number(x) and is_number(y) do
    # IO.puts "MOUSE release: #{inspect({x,y})}"
    pos = project_pos({x, y}, state)
    ViewPort.input(viewport, {:cursor_button, {:left, :release, 0, pos}})
    %{state | mouse_x: nil, mouse_y: nil, mouse_event: nil}
  end

  # send cursor_pos. no modifiers
  defp send_mouse(%{viewport: viewport, mouse_x: x, mouse_y: y, mouse_event: :mouse_move} = state)
       when is_number(x) and is_number(y) do
    # IO.puts "MOUSE move: #{inspect({x,y})}"
    pos = project_pos({x, y}, state)
    ViewPort.input(viewport, {:cursor_pos, pos})
    %{state | mouse_event: nil}
  end

  # generic mouse_up catch-all. For some reason a x or y was never set, so
  # this is invalid and the mouse state should be cleared
  defp send_mouse(%{mouse_event: :mouse_up} = state) do
    %{state | mouse_x: nil, mouse_y: nil, mouse_event: nil}
  end

  # fall-through. do nothing
  defp send_mouse(state) do
    state
  end

  # --------------------------------------------------------
  # project the measured x value by the calibration data to get the screen x
  defp project_pos({x, y}, %{calibration: {{ax, bx, dx}, {ay, by, dy}}}) do
    {
      x * ax + y * bx + dx,
      x * ay + y * by + dy
    }
  end

  defp project_pos(pos, _), do: pos
end
